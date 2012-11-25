##############################################################################
#
# This is the Salvus HUB module.  It runs as a daemon, sitting in the
# middle of the action, connected to potentially thousands of clients,
# many Sage sessions, and a Cassandra database cluster.  There are
# many HUBs running on VM's all over the installation.
#
# Run this by running ./hub [options]
#
# For local debugging, run this way, since it gives better stack traces.
#
#         make_coffee && echo "require('hub').start_server()" | coffee
#
##############################################################################
#

REQUIRE_ACCOUNT_TO_EXECUTE_CODE = false

# node.js -- builtin libraries
http    = require('http')
url     = require('url')
{EventEmitter} = require('events')

# salvus libraries
sage    = require("sage")               # sage server
misc    = require("misc")
defaults = misc.defaults; required = defaults.required
message = require("message")     # salvus message protocol
cass    = require("cassandra")
client_lib = require("client")

to_json = misc.to_json
to_safe_str = misc.to_safe_str
from_json = misc.from_json

# third-party libraries: add any new nodejs dependencies to the NODEJS_PACKAGES list in build.py
async   = require("async")
program = require('commander')          # command line arguments -- https://github.com/visionmedia/commander.js/
daemon  = require("start-stop-daemon")  # daemonize -- https://github.com/jiem/start-stop-daemon
winston = require('winston')            # logging -- https://github.com/flatiron/winston
sockjs  = require("sockjs")             # websockets (+legacy support) -- https://github.com/sockjs/sockjs-node
uuid    = require('node-uuid')

Cookies = require('cookies')            # https://github.com/jed/cookies

# module scope variables:
http_server        = null
database           = null

# the connected clients
clients            = {}

###
# HTTP Server
###

init_http_server = () ->
    http_server = http.createServer((req, res) ->

        {query, pathname} = url.parse(req.url, true)

        if pathname != '/alive'
            winston.info ("#{req.connection.remoteAddress} accessed #{req.url}")

        switch pathname
            when "/cookies"
                cookies = new Cookies(req, res)
                conn = clients[query.id]
                if conn?
                    if query.get
                        conn.emit("get_cookie-#{query.get}", cookies.get(query.get))
                    if query.set
                        x = conn.cookies[query.set]
                        delete conn.cookies[query.set]
                        cookies.set(query.set, x.value, x.options)
                        conn.emit("set_cookie-#{query.set}")
                res.end('')
            when "/alive"
                res.end('')
            else
                res.end('hub server')

    )


#############################################################
# Client = a client that is connected via sockjs to the hub
#############################################################
class Client extends EventEmitter
    constructor: (@conn) ->
        @ip_address = @conn.remoteAddress

        # The variable account_id is either undefined or set to the
        # account id of the user that this session has successfully
        # authenticated as.  Use @account_id to decide whether or not
        # it is safe to carry out a given action.
        @account_id = undefined

        @cookies = {}
        @remember_me_db = database.key_value_store(name: 'remember_me')

        @check_for_remember_me()

        @conn.on("data", @handle_message_from_client)
        @conn.on("close", () => delete clients[@conn.id])

    check_for_remember_me: () =>
        @get_cookie
            name : 'remember_me'
            cb   : (value) =>
                if value?
                    x    = value.split('$')
                    hash = generate_hash(x[0], x[1], x[2], x[3])
                    @remember_me_db.get
                        key : hash
                        cb  : (error, signed_in_mesg) =>
                            if not error and signed_in_mesg?
                                @hash_session_id = hash
                                @signed_in(signed_in_mesg)
                                @push_to_client(signed_in_mesg)

    #######################################################
    # Pushing messages to this particular connected client
    #######################################################
    push_to_client: (mesg) =>
        winston.debug("hub --> client: #{to_safe_str(mesg)}") if mesg.event != 'pong'
        @conn.write(to_json(mesg))

    error_to_client: (opts) ->
        opts = defaults opts,
            id    : required
            error : required
        @push_to_client(message.error(id:opts.id, error:opts.error))


    # Call this method when the user has successfully signed in.
    signed_in: (signed_in_mesg) =>

        # Record that this connection is authenticated:
        @account_id = signed_in_mesg.account_id

        record_sign_in
            ip_address    : @ip_address
            successful    : true
            remember_me   : signed_in_mesg.remember_me    # True if sign in accomplished via rememember me token.
            email_address : signed_in_mesg.email_address
            account_id    : signed_in_mesg.account_id
            first_name    : signed_in_mesg.first_name
            last_name     : signed_in_mesg.last_name


    signed_out: () =>
        @account_id = undefined

    #########################################################
    # Setting and getting HTTPonly cookies via SockJS + AJAX
    #########################################################
    get_cookie: (opts) ->
        opts = defaults opts,
            name : required
            cb   : required   # cb(value)
        @once("get_cookie-#{opts.name}", (value) -> opts.cb(value))
        @push_to_client(message.cookies(id:@conn.id, get:opts.name))

    set_cookie: (opts) ->
        opts = defaults opts,
            name  : required
            value : required
            ttl   : undefined    # time in seconds until cookie expires
            cb    : undefined    # cb() when cookie is set
        options = {}
        if opts.ttl?
            options.expires = new Date(new Date().getTime() + 1000*opts.ttl)
        @once("set_cookie-#{opts.name}", ()->opts.cb?())
        @cookies[opts.name] = {value:opts.value, options:options}
        @push_to_client(message.cookies(id:@conn.id, set:opts.name))

    remember_me: (opts) ->
        #############################################################
        # Remember me.  There are many ways to implement
        # "remember me" functionality in a web app. Here's how
        # we do it with Salvus.  We generate a random uuid,
        # which along with salt, is stored in the user's
        # browser as an httponly cookie.  We password hash the
        # random uuid and store that in our database.  When
        # the user later visits the Salvus site, their browser
        # sends the cookie, which the server hashes to get the
        # key for the database table, which has corresponding
        # value the mesg needed for sign in.  We then sign the
        # user in using that message.
        #
        # The reason we use a password hash is that if
        # somebody gains access to an entry in the key:value
        # store of the database, we want to ensure that they
        # can't use that information to login.  The only way
        # they could login would be by gaining access to the
        # cookie in the user's browser.
        #
        # There is no point in signing the cookie since its
        # contents are random.
        #
        # Regarding ttl, we use 1 week.  The database will forget
        # the cookie automatically at the same time that the
        # browser invalidates it.
        #############################################################

        opts = defaults opts,
            account_id    : required
            first_name    : required
            last_name     : required
            email_address : required

        opts.remember_me = true
        signed_in_mesg   = message.signed_in(opts)
        session_id       = uuid.v4()
        @hash_session_id = password_hash(session_id)
        ttl              = 7*24*3600     # 7 days

        @remember_me_db.set
            key   : @hash_session_id
            value : signed_in_mesg
            ttl   : ttl

        x = @hash_session_id.split('$')    # format:  algorithm$salt$iterations$hash
        @set_cookie
            name  : 'remember_me'
            value : [x[0], x[1], x[2], session_id].join('$')
            ttl   : ttl

    invalidate_remember_me: (opts) ->
        opts = defaults opts,
            cb : required

        if @hash_session_id?
            @remember_me_db.delete
                key : @hash_session_id
                cb  : opts.cb
        else
            opts.cb()

    ################################################################
    # Message handling functions:
    #
    # Each function below that starts with mesg_ handles a given
    # message type (an event).  The implementations of many of the
    # handlers are somewhat long/involved, so the function below
    # immediately calls another function defined elsewhere.  This will
    # make it easier to refactor code to other modules, etc., later.
    # This approach also clarifies what exactly about this object
    # is used to implement the relevant functionality.
    ################################################################

    handle_message_from_client: (data) =>
        try
            mesg = from_json(data)
        catch error
            winston.error("error parsing incoming mesg (invalid JSON): #{mesg}")
            return

        if mesg.event != 'ping'
            winston.debug("client --> hub: #{to_safe_str(mesg)}")

        handler = @["mesg_#{mesg.event}"]
        if handler?
            handler(mesg)
        else
            @push_to_client(message.error(error:"Salvus server does not know how to handle the #{mesg.event} event.", id:mesg.id))

    ######################################################
    # Messages: Sage compute sessions and code execution
    ######################################################
    mesg_execute_code: (mesg) =>
        if REQUIRE_ACCOUNT_TO_EXECUTE_CODE and not @account_id?
            @push_to_client(message.error(id:mesg.id, error:"You must be signed in to execute code."))
            return
        if mesg.session_uuid?
            send_to_persistent_sage_session(mesg, @account_id)
        else
            stateless_sage_exec(mesg, @push_to_client)

    mesg_start_session: (mesg) =>
        if REQUIRE_ACCOUNT_TO_EXECUTE_CODE and not @account_id?
            @push_to_client(message.error(id:mesg.id, error:"You must be signed in to start a session."))
            return
        create_persistent_sage_session(mesg, @account_id, @push_to_client)

    mesg_send_signal: (mesg) =>
        if REQUIRE_ACCOUNT_TO_EXECUTE_CODE and not @account_id?
            @push_to_client(message.error(id:mesg.id, error:"You must be signed in to send a signal."))
            return
        send_to_persistent_sage_session(mesg, @account_id)

    ######################################################
    # Message: Introspections
    #   - completions of an identifier / methods on an object (may result in code evaluation)
    #   - docstring of function/object
    #   - source code of function/class
    ######################################################
    mesg_introspect: (mesg) =>
        if REQUIRE_ACCOUNT_TO_EXECUTE_CODE and not @account_id?
            @push_to_client(message.error(id:mesg.id, error:"You must be signed in to send a signal."))
            return

        send_to_persistent_sage_session(mesg, @account_id)

    ######################################################
    # Messages: Keeping client connected
    ######################################################
    # ping/pong
    mesg_ping: (mesg) =>
        @push_to_client(message.pong(id:mesg.id))

    ######################################################
    # Messages: Account creation, sign in, sign out
    ######################################################
    mesg_create_account: (mesg) => create_account(@, mesg)

    mesg_sign_in: (mesg) => sign_in(@,mesg)

    mesg_sign_out: (mesg) =>
        if not @account_id?
            @push_to_client(message.error(id:mesg.id, error:"Not signed in."))
            return

        @signed_out()
        @invalidate_remember_me
            cb:(error) =>
                winston.debug("signing out: #{mesg.id}, #{error}")
                if not error
                    @push_to_client(message.error(id:mesg.id, error:error))
                else
                    @push_to_client(message.signed_out(id:mesg.id))

    ######################################################
    # Messages: Password/email address management
    ######################################################
    mesg_password_reset: (mesg) =>
        password_reset(mesg, @ip_address, @push_to_client)

    mesg_change_password: (mesg) =>
        change_password(mesg, @ip_address, @push_to_client)

    mesg_forgot_password: (mesg) =>
        forgot_password(mesg, @ip_address, @push_to_client)

    mesg_reset_forgot_password: (mesg) =>
        reset_forgot_password(mesg, @ip_address, @push_to_client)

    mesg_change_email_address: (mesg) =>
        change_email_address(mesg, @ip_address, @push_to_client)

    ######################################################
    # Messages: Account settings
    ######################################################
    mesg_get_account_settings: (mesg) =>
        if @account_id != mesg.account_id
            @push_to_client(message.error(id:mesg.id, error:"Not signed in as user with id #{mesg.account_id}."))
        else
            get_account_settings(mesg, @push_to_client)

    mesg_account_settings: (mesg) =>
        if @account_id != mesg.account_id
            @push_to_client(message.error(id:mesg.id, error:"Not signed in as user with id #{mesg.account_id}."))
        else
            save_account_settings(mesg, @push_to_client)

    ######################################################
    # Messages: Client feedback
    ######################################################
    mesg_report_feedback: (mesg) =>
        report_feedback(mesg, @push_to_client, @account_id)

    mesg_get_all_feedback_from_user: (mesg) =>
        get_all_feedback_from_user(mesg, @push_to_client, @account_id)

    ######################################################
    # Messages: Project Management
    ######################################################
    mesg_create_project: (mesg) =>
        if not @account_id?
            @error_to_client(id: mesg.id, error: "You must be signed in to create a new project.")
            return
        project_id = uuid.v4()
        # create project in database
        database.create_project
            project_id  : project_id
            account_id  : @account_id
            title       : mesg.title
            description : mesg.description
            public      : mesg.public
            cb          : (error, result) =>
                if error
                    @error_to_client(id: mesg.id, error: "Failed to insert new project into the database.")
                else
                    @push_to_client(message.project_created(id:mesg.id, project_id:project_id))
                    push_to_clients  # push a message to all other clients logged in as this user.
                        where : {account_id:@account_id,  exclude: [@conn.id]}
                        mesg  : message.project_list_updated()

    mesg_get_projects: (mesg) =>
        if not @account_id?
            @error_to_client(id: mesg.id, error: "You must be signed in to get a list of projects.")
            return

        database.get_projects_with_user
            account_id : @account_id
            cb         : (error, projects) =>
                if error
                    @error_to_client(id: mesg.id, error: "Database error -- failed to obtain list of your projects.")
                else
                    # sort them by last_edited (something db doesn't do)
                    projects.sort((a,b) -> if a.last_edited < b.last_edited then +1 else -1)
                    @push_to_client(message.all_projects(id:mesg.id, projects:projects))

    mesg_update_project_data: (mesg) =>
        if not @account_id?
            @error_to_client(id: mesg.id, error: "You must be signed in to set data about a project.")
            return
        project_is_owned_by
            project_id : mesg.project_id
            account_id : @account_id
            cb: (error, ok) =>
                if error
                    @error_to_client(id:mesg.id, error:error)
                    return
                else if not ok
                    @error_to_client(id:mesg.id, error:"You do not own the project with id #{mesg.project_id}.")
                else
                    # sanatize the mesg.data object -- we don't want client to just be able to set anything about a project.
                    data = {}
                    for field in ['title', 'description', 'public']
                        if mesg.data[field]?
                            data[field] = mesg.data[field]
                    database.update
                        table   : "projects"
                        where   : {project_id:mesg.project_id}
                        set     : data
                        cb      : (error, result) =>
                            if error
                                @error_to_client(id:mesg.id, error:"Database error changing properties of the project with id #{mesg.project_id}.")
                            else
                                push_to_clients
                                    where : {project_id:mesg.project_id, account_id:@account_id}
                                    mesg  : message.project_data_updated(id:mesg.id, project_id:mesg.project_id)


project_is_owned_by = (opts) ->
    opts = defaults opts,
        project_id : required
        account_id : required
        cb : required         # input: (error, result) where if defined result is true or false

    database.count
        table : 'projects'
        where : {project_id: opts.project_id, account_id: opts.account_id}
        cb : (error, n) ->
            if error
                opts.cb(error)
            else
                opts.cb(false, n==1)

    database.select
        table   : 'projects'
        columns : ['account_id']
        where   : {project_id : opts.project_id}
        cb : (error, result) ->
            if error
                opts.cb(error, false)
            else
                if result.length == 0
                    opts.cb("There is no project with id #{mesg.project_id}.", false)
                else
                    if result[0][0] != opts.account_id
                        opts.cb(false, false)  # not an error -- just account_id does not own it.
                    else:
                        opts.cb(false, true)



##############################
# Create the SockJS Server
##############################
init_sockjs_server = () ->
    sockjs_server = sockjs.createServer()

    sockjs_server.on "connection", (conn) ->
        clients[conn.id] = new Client(conn)

    sockjs_server.installHandlers(http_server, {prefix:'/hub'})


#######################################################
# Pushing a message to clients; querying for clients
# This is (or will be) subtle, due to having
# multiple HUBs running on different computers.
#######################################################

# get_client_ids -- given query parameters, returns a list of id's,
#   where the id is the SockJS connection id, which we assume is
#   globally unique across all of space and time.
get_client_ids = (opts) ->
    opts = defaults opts,
        account_id : undefined      # include connected clients logged in under this account
        project_id : undefined      # include connected clients that are a user of this project
        exclude    : undefined      # array of id's to exclude from results
        cb         : required

    result = []
    include = (id) ->
        if id not in result
            if opts.exclude?
                if id in opts.exclude
                    return
            result.push(id)

    async.series([
        (cb) ->
            if opts.project_id?
                database.get_account_ids_using_project
                    project_id : opts.project_id
                    cb : (error, result) ->
                        if (error)
                            opts.cb(error)
                            cb(true)
                        else
                            for id in result
                                include(id)
                            cb()
            else
                cb()
        (cb) ->
            # TODO: This will be replaced by one scalable database query on an indexed column
            if opts.account_id?
                for id, client of clients
                    if client.account_id == opts.account_id
                        include(id)
            opts.cb(false, result)
            cb()
    ])


# Send a message to a bunch of clients, connected either to this hub
# or other hubs (local clients first).
push_to_clients = (opts) ->
    opts = defaults opts,
        mesg     : required
        where    : undefined  # see the get_client_ids function
        to       : undefined
        cb       : undefined

    dest = []

    async.series([
        (cb) ->
            if opts.where?
                get_client_ids(misc.merge(opts.where, cb:(error, result) ->
                    if error
                        opts.cb?(true)
                        cb(true)
                    else
                        dest = dest.concat(result)
                        cb()
                ))
            else
                cb()

        (cb) ->
            # include all clients explicitly listed in "to"
            if opts.to?
                dest = dest.concat(opts.to)

            # IMPORTANT TODO: extend to use database and inter-hub communication
            console.log("dest = #{dest}")
            for i of clients
                console.log("current client id: #{i}")
            for id in dest
                console.log(id)
                clients[id]?.push_to_client(opts.mesg)
            opts.cb?(false)
            cb()


    ])


########################################
# Passwords
########################################

password_hash_library = require('password-hash')
crypto = require('crypto')

# You can change the parameters at any time and no existing passwords
# or cookies should break.  This will only impact newly created
# passwords and cookies.  Old ones can be read just fine (with the old
# parameters).
HASH_ALGORITHM   = 'sha512'
HASH_ITERATIONS  = 1000
HASH_SALT_LENGTH = 32

# This function is private and burried inside the password-hash
# library.  To avoid having to fork/modify that library, we've just
# copied it here.  We need it for remember_me cookies.
generate_hash = (algorithm, salt, iterations, password) ->
    iterations = iterations || 1
    hash = password
    for i in [1..iterations]
        hash = crypto.createHmac(algorithm, salt).update(hash).digest('hex')
    return algorithm + '$' + salt + '$' + iterations + '$' + hash

exports.password_hash = password_hash = (password) ->
    return password_hash_library.generate(password,
        algorithm  : HASH_ALGORITHM
        saltLength : HASH_SALT_LENGTH
        iterations : HASH_ITERATIONS   # This blocks the server for about 10 milliseconds...
    )

# Password checking.  opts.cb(false, true) if the
# password is correct, opts.cb(true) on error (e.g., loading from
# database), and opts.cb(false, false) if password is wrong.  You must
# specify exactly one of password_hash, account_id, or email_address.
# In case you specify password_hash, in addition to calling the
# callback (if specified), this function also returns true if the
# password is correct, and false otherwise; it can do this because
# there is no async IO when the password_hash is specified.
is_password_correct = (opts) ->
    opts = defaults opts,
        password      : required
        cb            : undefined
        password_hash : undefined
        account_id    : undefined
        email_address : undefined
    if opts.password_hash?
        r = password_hash_library.verify(opts.password, opts.password_hash)
        opts.cb?(false, r)
        return r
    else if opts.account_id? or opts.email_address?
        database.get_account
            account_id    : opts.account_id
            email_address : opts.email_address
            columns       : ['password_hash']
            cb            : (error, account) ->
                if error
                    opts.cb?(error)
                else
                    opts.cb?(false, password_hash_library.verify(opts.password, account.password_hash))
    else
        opts.cb?("One of password_hash, account_id, or email_address must be specified.")



########################################
# Account Management
########################################

password_crack_time = (password) -> Math.floor(zxcvbn.zxcvbn(password).crack_time/(3600*24.0)) # time to crack in days

#############################################################################
# User sign in
#
# Anti-DOS cracking throttling policy:
#
#   * POLICY 1: A given email address is allowed at most 3 failed login attempts per minute.
#   * POLICY 2: A given email address is allowed at most 10 failed login attempts per hour.
#   * POLICY 3: A given ip address is allowed at most 10 failed login attempts per minute.
#   * POLICY 4: A given ip address is allowed at most 25 failed login attempts per hour.
#############################################################################
sign_in = (client, mesg) =>
    sign_in_error = (error) ->
        client.push_to_client(message.sign_in_failed(id:mesg.id, email_address:mesg.email_address, reason:error))

    if mesg.email_address == ""
        sign_in_error("Empty email address.")
        return

    if mesg.password == ""
        sign_in_error("Empty password.")
        return

    signed_in_mesg = null
    async.series([
        # POLICY 1: A given email address is allowed at most 3 failed login attempts per minute.
        (cb) ->
            database.count
                table: "failed_sign_ins_by_email_address"
                where: {email_address:mesg.email_address, time: {'>=':cass.minutes_ago(1)}}
                cb: (error, count) ->
                    if error
                        sign_in_error(error)
                        cb(true); return
                    if count > 3
                        sign_in_error("A given email address is allowed at most 3 failed login attempts per minute. Please wait.")
                        cb(true); return
                    cb()
        # POLICY 2: A given email address is allowed at most 10 failed login attempts per hour.
        (cb) ->
            database.count
                table: "failed_sign_ins_by_email_address"
                where: {email_address:mesg.email_address, time: {'>=':cass.hours_ago(1)}}
                cb: (error, count) ->
                    if error
                        sign_in_error(error)
                        cb(true); return
                    if count > 10
                        sign_in_error("A given email address is allowed at most 10 failed login attempts per hour. Please wait.")
                        cb(true); return
                    cb()

        # POLICY 3: A given ip address is allowed at most 10 failed login attempts per minute.
        (cb) ->
            database.count
                table: "failed_sign_ins_by_ip_address"
                where: {ip_address:client.ip_address, time: {'>=':cass.minutes_ago(1)}}
                cb: (error, count) ->
                    if error
                        sign_in_error(error)
                        cb(true); return
                    if count > 10
                        sign_in_error("A given ip address is allowed at most 10 failed login attempts per minute. Please wait.")
                        cb(true); return
                    cb()

        # POLICY 4: A given ip address is allowed at most 25 failed login attempts per hour.
        (cb) ->
            database.count
                table: "failed_sign_ins_by_ip_address"
                where: {ip_address:client.ip_address, time: {'>=':cass.hours_ago(1)}}
                cb: (error, count) ->
                    if error
                        sign_in_error(error)
                        cb(true); return
                    if count > 25
                        sign_in_error("A given ip address is allowed at most 25 failed login attempts per hour. Please wait.")
                        cb(true); return
                    cb()

        # get account and check credentials
        (cb) ->
            database.get_account
                email_address : mesg.email_address
                cb            : (error, account) ->
                    if error
                        record_sign_in
                            ip_address    : client.ip_address
                            successful    : false
                            email_address : mesg.email_address
                        sign_in_error(error)
                        cb(true); return
                    if not is_password_correct(password:mesg.password, password_hash:account.password_hash)
                        record_sign_in
                            ip_address    : client.ip_address
                            successful    : false
                            email_address : mesg.email_address
                            account_id    : account.account_id
                        sign_in_error("Invalid password for #{mesg.email_address}.")
                        cb(true); return
                    else

                        signed_in_mesg = message.signed_in
                            id            : mesg.id
                            account_id    : account.account_id
                            first_name    : account.first_name
                            last_name     : account.last_name
                            email_address : mesg.email_address
                            remember_me   : false

                        client.signed_in(signed_in_mesg)
                        client.push_to_client(signed_in_mesg)
                        cb()

        # remember me
        (cb) ->
            if mesg.remember_me
                client.remember_me
                    account_id : signed_in_mesg.account_id
                    first_name : signed_in_mesg.first_name
                    last_name  : signed_in_mesg.last_name
                    email_address : signed_in_mesg.email_address
            cb()
    ])


# Record to the database a failed and/or successful login attempt.
record_sign_in = (opts) ->
    opts = defaults opts,
        ip_address    : required
        successful    : required
        email_address : required
        first_name    : undefined
        last_name     : undefined
        account_id    : undefined
        remember_me   : false
    if not opts.successful
        database.update
            table : 'failed_sign_ins_by_ip_address'
            set   : {email_address:opts.email_address}
            where : {time:cass.now(), ip_address:opts.ip_address}
        database.update
            table : 'failed_sign_ins_by_email_address'
            set   : {ip_address:opts.ip_address}
            where : {time:cass.now(), email_address:opts.email_address}
    else
        database.update
            table : 'successful_sign_ins'
            set   : {ip_address:opts.ip_address, first_name:opts.first_name, last_name:opts.last_name, email_address:opts.email_address, remember_me:opts.remember_me}
            where : {time:cass.now(), account_id:opts.account_id}



# We cannot put the zxcvbn password strength checking in
# client.coffee since it is too big (~1MB).  The client
# will async load and use this, of course, but a broken or
# *hacked* client might not properly verify this, so we
# do it in the server too.  NOTE: I tested Dropbox and
# they have a GUI to warn against week passwords, but still
# allow them anyways!
zxcvbn = require('../static/zxcvbn/zxcvbn')  # this require takes about 100ms!


# Current policy is to allow all but trivial passwords for user convenience.
# To change this, just increase this number.
MIN_ALLOWED_PASSWORD_STRENGTH = 1

is_valid_password = (password) ->
    [valid, reason] = client_lib.is_valid_password(password)
    if not valid
        return [valid, reason]
    password_strength = zxcvbn.zxcvbn(password)  # note -- this is synchronous (but very fast, I think)
    console.log("password strength = #{password_strength}")
    if password_strength.score < MIN_ALLOWED_PASSWORD_STRENGTH
        return [false, "Choose a password that isn't very weak."]
    return [true, '']


create_account = (client, mesg) ->
    id = mesg.id
    account_id = null
    async.series([
        # run tests on generic validity of input
        (cb) ->
            issues = client_lib.issues_with_create_account(mesg)

            # Do not allow *really* stupid passwords.
            [valid, reason] = is_valid_password(mesg.password)
            if not valid
                issues['password'] = reason

            # TODO -- only uncomment this for easy testing, allow any password choice
            # the client test suite will then fail, which is good, so we are reminded to comment this out before release!
            # delete issues['password']

            if misc.len(issues) > 0
                client.push_to_client(message.account_creation_failed(id:id, reason:issues))
                cb(true)
            else
                cb()

        # make sure this ip address hasn't requested more than 100
        # accounts in the last 6 hours (just to avoid really nasty
        # evils, but still allow for demo registration behind a wifi
        # router -- say)
        (cb) ->
            ip_tracker = database.key_value_store(name:'create_account_ip_tracker')
            ip_tracker.get(
                key : client.ip_address
                cb  : (error, value) ->
                    if error
                        client.push_to_client(message.account_creation_failed(id:id, reason:{'other':"Unable to create account.  Please try later."}))
                        cb(true)
                    if not value?
                        ip_tracker.set(key: client.ip_address, value:1, ttl:6*3600)
                        cb()
                    else if value < 100
                        ip_tracker.set(key: client.ip_address, value:value+1, ttl:6*3600)
                        cb()
                    else # bad situation
                        database.log(
                            event : 'create_account'
                            value : {ip_address:client.ip_address, reason:'too many requests'}
                        )
                        client.push_to_client(message.account_creation_failed(id:id, reason:{'other':"Too many account requests from the ip address #{client.ip_address} in the last 6 hours.  Please try again later."}))
                        cb(true)
            )

        # query database to determine whether the email address is available
        (cb) ->
            database.is_email_address_available(mesg.email_address, (error, available) ->
                if error
                    client.push_to_client(message.account_creation_failed(id:id, reason:{'other':"Unable to create account.  Please try later."}))
                    cb(true)
                else if not available
                    client.push_to_client(message.account_creation_failed(id:id, reason:{email_address:"This e-mail address is already taken."}))
                    cb(true)
                else
                    cb()
            )

        # create new account
        (cb) ->
            database.create_account(
                first_name:    mesg.first_name
                last_name:     mesg.last_name
                email_address: mesg.email_address
                password_hash: password_hash(mesg.password)
                cb: (error, result) ->
                    if error
                        client.push_to_client(message.account_creation_failed(
                                 id:id, reason:{'other':"Unable to create account right now.  Please try later."})
                        )
                        cb(true)
                    account_id = result
                    database.log(
                        event : 'create_account'
                        value : {account_id:account_id, first_name:mesg.first_name, last_name:mesg.last_name, email_address:mesg.email_address}
                    )
                    cb()
            )

        # send message back to user that they are logged in as the new user
        (cb) ->
            mesg = message.signed_in
                id            : mesg.id
                account_id    : account_id
                remember_me   : false
                first_name    : mesg.first_name
                last_name     : mesg.last_name
                email_address : mesg.email_address
            client.signed_in(mesg)
            client.push_to_client(mesg)
            cb()
    ])


change_password = (mesg, client_ip_address, push_to_client) ->
    account = null
    async.series([
        # make sure there hasn't been a password change attempt for this
        # email address in the last 5 seconds
        (cb) ->
            tracker = database.key_value_store(name:'change_password_tracker')
            tracker.get(
                key : mesg.email_address
                cb : (error, value) ->
                    if error
                        cb()  # DB error, so don't bother with the tracker
                        return
                    if value?  # is defined, so problem -- it's over
                        push_to_client(message.changed_password(id:mesg.id, error:{'too_frequent':'Please wait at least 5 seconds before trying to change your password again.'}))
                        database.log(
                            event : 'change_password'
                            value : {email_address:mesg.email_address, client_ip_address:client_ip_address, message:"attack?"}
                        )
                        cb(true)
                        return
                    else
                        # record change in tracker with ttl (don't care about confirming that this succeeded)
                        tracker.set(
                            key   : mesg.email_address
                            value : client_ip_address
                            ttl   : 5
                        )
                        cb()
            )

        # get account and validate the password
        (cb) ->
            database.get_account(
              email_address : mesg.email_address
              cb : (error, result) ->
                if error
                    push_to_client(message.changed_password(id:mesg.id, error:{other:error}))
                    cb(true)
                    return
                account = result
                if not is_password_correct(password:mesg.old_password, password_hash:account.password_hash)
                    push_to_client(message.changed_password(id:mesg.id, error:{old_password:"Invalid old password."}))
                    database.log(
                        event : 'change_password'
                        value : {email_address:mesg.email_address, client_ip_address:client_ip_address, message:"Invalid old password."}
                    )
                    cb(true)
                    return
                cb()
            )

        # check that new password is valid
        (cb) ->
            [valid, reason] = is_valid_password(mesg.new_password)
            if not valid
                push_to_client(message.changed_password(id:mesg.id, error:{new_password:reason}))
                cb(true)
            else
                cb()

        # record current password hash (just in case?) and that we are changing password and set new password
        (cb) ->

            database.log(
                event : "change_password"
                value :
                    account_id : account.account_id
                    client_ip_address : client_ip_address
                    previous_password_hash : account.password_hash
            )

            database.change_password(
                account_id:    account.account_id
                password_hash: password_hash(mesg.new_password),
                cb : (error, result) ->
                    if error
                        push_to_client(message.changed_password(id:mesg.id, error:{misc:error}))
                    else
                        push_to_client(message.changed_password(id:mesg.id, error:false)) # finally, success!
                    cb()
            )
    ])


change_email_address = (mesg, client_ip_address, push_to_client) ->

    if mesg.old_email_address == mesg.new_email_address  # easy case
        push_to_client(message.changed_email_address(id:mesg.id))
        return

    if not client_lib.is_valid_email_address(mesg.new_email_address)
        push_to_client(message.changed_email_address(id:mesg.id, error:'email_invalid'))
        return

    async.series([
        # Make sure there hasn't been an email change attempt for this
        # email address in the last 5 seconds:
        (cb) ->
            WAIT = 5
            tracker = database.key_value_store(name:'change_email_address_tracker')
            tracker.get(
                key : mesg.old_email_address
                cb : (error, value) ->
                    if error
                        push_to_client(message.changed_email_address(id:mesg.id, error:error))
                        cb(true)
                        return
                    if value?  # is defined, so problem -- it's over
                        push_to_client(message.changed_email_address(id:mesg.id, error:'too_frequent', ttl:WAIT))
                        database.log(
                            event : 'change_email_address'
                            value : {email_address:mesg.old_email_address, client_ip_address:client_ip_address, message:"attack?"}
                        )
                        cb(true)
                        return
                    else
                        # record change in tracker with ttl (don't care about confirming that this succeeded)
                        tracker.set(
                            key   : mesg.old_email_address
                            value : client_ip_address
                            ttl   : WAIT    # seconds
                        )
                        cb()
            )

        # validate the password
        (cb) ->
            is_password_correct
                account_id    : mesg.account_id
                password      : mesg.password
                cb : (error, is_correct) ->
                    if error
                        push_to_client(message.changed_email_address(id:mesg.id, error:"Server error checking password."))
                        cb(true)
                        return
                    else if not is_correct
                        push_to_client(message.changed_email_address(id:mesg.id, error:"invalid_password"))
                        cb(true)
                        return
                    cb()

        # Record current email address (just in case?) and that we are
        # changing email address to the new one.  This will make it
        # easy to implement a "change your email address back" feature
        # if I need to at some point.
        (cb) ->
            database.log(event : 'change_email_address', value : {client_ip_address : client_ip_address, old_email_address : mesg.old_email_address, new_email_address : mesg.new_email_address})

            #################################################
            # TODO: At this point, we should send an email to
            # old_email_address with a hash-code that can be used
            # to undo the change to the email address.
            #################################################

            database.change_email_address
                account_id    : mesg.account_id
                email_address : mesg.new_email_address
                cb : (error, success) ->
                    if error
                        push_to_client(message.changed_email_address(id:mesg.id, error:error))
                    else
                        push_to_client(message.changed_email_address(id:mesg.id)) # finally, success!
                    cb()
    ])


#############################################################################
# Send an email message to the given email address with a code that
# can be used to reset the password for a certain account.
#
# Anti-use-salvus-to-spam/DOS throttling policies:
#   * a given email address can be sent at most 2 password resets per hour
#   * a given ip address can send at most 3 password reset request per minute
#   * a given ip can send at most 25 per hour
#############################################################################
forgot_password = (mesg, client_ip_address, push_to_client) ->
    if mesg.event != 'forgot_password'
        push_to_client(message.error(id:mesg.id, error:"Incorrect message event type: #{mesg.event}"))
        return

    # This is an easy check to save work and also avoid empty email_address, which causes CQL trouble.
    if not client_lib.is_valid_email_address(mesg.email_address)
        push_to_client(message.error(id:mesg.id, error:"Invalid email address."))
        return

    id = null
    async.series([
        # record this password reset attempt in our database
        (cb) ->
            database.update
                table   : 'password_reset_attempts_by_ip_address'
                set     : {email_address:mesg.email_address}
                where   : {ip_address:client_ip_address, time:cass.now()}
                cb      : (error, result) ->
                    if error
                        push_to_client(message.forgot_password_response(id:mesg.id, error:"Database error: #{error}"))
                        cb(true); return
                    else
                        cb()
        (cb) ->
            database.update
                table   : 'password_reset_attempts_by_email_address'
                set     : {ip_address:client_ip_address}
                where   : {email_address:mesg.email_address, time:cass.now()}
                cb      : (error, result) ->
                    if error
                        push_to_client(message.forgot_password_response(id:mesg.id, error:"Database error: #{error}"))
                        cb(true); return
                    else
                        cb()

        # POLICY 1: We limit the number of password resets that an email address can receive to at most 2 per hour
        (cb) ->
            database.count
                table   : "password_reset_attempts_by_email_address"
                where   : {email_address:mesg.email_address, time:{'>=':cass.hours_ago(1)}}
                cb      : (error, count) ->
                    if error
                        push_to_client(message.forgot_password_response(id:mesg.id, error:"Database error: #{error}"))
                        cb(true); return
                    if count >= 3
                        push_to_client(message.forgot_password_response(id:mesg.id, error:"Salvus will not send more than 2 password resets to #{mesg.email_address} per hour."))
                        cb(true)
                        return
                    cb()

        # POLICY 2: a given ip address can send at most 3 password reset request per minute
        (cb) ->
            database.count
                table   : "password_reset_attempts_by_ip_address"
                where   : {ip_address:client_ip_address,  time:{'>=':cass.hours_ago(1)}}
                cb      : (error, count) ->
                    if error
                        push_to_client(message.forgot_password_response(id:mesg.id, error:"Database error: #{error}"))
                        cb(true); return
                    if count >= 4
                        push_to_client(message.forgot_password_response(id:mesg.id, error:"Please wait a minute before sending another password reset request from the ip address #{client_ip_address}."))
                        cb(true); return
                    cb()


        # POLICY 3: a given ip can send at most 25 per hour
        (cb) ->
            database.count
                table : "password_reset_attempts_by_ip_address"
                where : {ip_address:client_ip_address, time:{'>=':cass.hours_ago(1)}}
                cb    : (error, count) ->
                    if error
                        push_to_client(message.forgot_password_response(id:mesg.id, error:"Database error: #{error}"))
                        cb(true); return
                    if count >= 26
                        push_to_client(message.forgot_password_response(id:mesg.id, error:"There have been too many password reset requests from #{client_ip_address}.  Wait an hour before sending any more password reset requests."))
                        cb(true); return
                    cb()

        (cb) ->
            database.get_account(
                email_address : mesg.email_address
                cb            : (error, account) ->
                    if error # no such account
                        push_to_client(message.forgot_password_response(id:mesg.id, error:"No account with e-mail address #{mesg.email_address}."))
                        cb(true); return
                    else
                        cb()
            )

        # We now know that there is an account with this email address.
        # put entry in the password_reset uuid:value table with ttl of 15 minutes, and send an email
        (cb) ->
            id = database.uuid_value_store(name:"password_reset").set(
                value : mesg.email_address
                ttl   : 60*15,
                cb    : (error, results) ->
                    if error
                        push_to_client(message.forgot_password_response(id:mesg.id, error:"Internal Salvus error generating password reset for #{mesg.email_address}."))
                        cb(true); return
                    else
                        cb()
            )

        # send an email to mesg.email_address that has a link to
        (cb) ->
            body = """
                Somebody just requested to change the password on your Salvus account.
                If you requested this password change, please change your password by
                following the link below:

                     https://salv.us#forgot##{id}

                If you don't want to change your password, ignore this message.
                """

            send_email
                subject : 'Salvus password reset confirmation'
                body    : body
                to      : mesg.email_address
                cb      : (error) ->
                    if error
                        push_to_client(message.forgot_password_response(id:mesg.id, error:"Internal Salvus error sending password reset email to #{mesg.email_address}."))
                        cb(true)
                    else
                        push_to_client(message.forgot_password_response(id:mesg.id))
                        cb()
    ])


reset_forgot_password = (mesg, client_ip_address, push_to_client) ->
    if mesg.event != 'reset_forgot_password'
        push_to_client(message.error(id:mesg.id, error:"incorrect message event type: #{mesg.event}"))
        return

    email_address = account_id = db = null

    async.series([
        # check that request is valid
        (cb) ->
            db = database.uuid_value_store(name:"password_reset")
            db.get
                uuid : mesg.reset_code
                cb   : (error, value) ->
                    if error
                        push_to_client(message.reset_forgot_password_response(id:mesg.id, error:error))
                        cb(true); return
                    if not value?
                        push_to_client(message.reset_forgot_password_response(id:mesg.id, error:"This password reset request is no longer valid."))
                        cb(true); return
                    email_address = value
                    cb()

        # Verify password is valid and compute its hash.
        (cb) ->
            [valid, reason] = is_valid_password(mesg.new_password)
            if not valid
                push_to_client(message.reset_forgot_password_response(id:mesg.id, error:reason))
                cb(true)
            else
                cb()

        # Get the account_id.
        (cb) ->
            database.get_account
                email_address : email_address
                columns       : ['account_id']
                cb            : (error, account) ->
                    if error
                        push_to_client(message.reset_forgot_password_response(id:mesg.id, error:error))
                        cb(true)
                    else
                        account_id = account.account_id
                        cb()

        # Make the change
        (cb) ->
            database.change_password
                account_id: account_id
                password_hash : password_hash(mesg.new_password)
                cb : (error, account) ->
                    if error
                        push_to_client(message.reset_forgot_password_response(id:mesg.id, error:error))
                        cb(true)
                    else
                        push_to_client(message.reset_forgot_password_response(id:mesg.id)) # success
                        db.delete(uuid: mesg.reset_code)  # only allow successful use of this reset token once
                        cb()
    ])

# This function sends a message to the client (via push_to_client)
# with the account settings for the account with given id.  We assume
# that caller code has already determined that the user initiating
# this request has the given account_id.
get_account_settings = (mesg, push_to_client) ->
    account_settings = null
    async.series([
        # 1. Get entry in the database corresponding to this account.
        (cb) ->
            database.get_account
                account_id : mesg.account_id
                cb : (error, data) ->
                    if error
                        push_to_client(message.error(id:mesg.id, error:error))
                        cb(true) # bail
                    else
                        # 2. Set defaults for unset keys.  We do this so that in the
                        # long run it will always be easy to migrate the database
                        # forward (with new columns).
                        delete data['password_hash']

                        for key, val of message.account_settings_defaults
                            if not data[key]?
                                data[key] = val

                        account_settings = data
                        account_settings.id = mesg.id
                        cb()

        # 3. Get information about user plan
        (cb) ->
            database.get_plan
                plan_id : account_settings['plan_id']
                cb : (error, plan) ->
                    if error
                        push_to_client(message.error(id:mesg.id, error:error))
                        cb(true) # bail out
                    else
                        account_settings.plan_name = plan.name
                        account_settings.storage_limit = plan.storage_limit
                        account_settings.session_limit = plan.session_limit
                        account_settings.max_session_time = plan.max_session_time
                        account_settings.ram_limit = plan.ram_limit
                        account_settings.support_level = plan.support_level

                        # 4. Send result to client
                        push_to_client(message.account_settings(account_settings))
                        cb() # done!
    ])

# mesg is an account_settings message.  We save everything in the
# message to the database.  The restricted settings are completely
# ignored if mesg.password is not set and correct.
save_account_settings = (mesg, push_to_client) ->
    if mesg.event != 'account_settings'
        push_to_client(message.error(id:mesg.id, error:"Wrong message type: #{mesg.event}"))
        return
    settings = {}
    for key of message.unrestricted_account_settings
        settings[key] = mesg[key]
    database.update_account_settings
        account_id : mesg.account_id
        settings   : settings
        cb         : (error, results) ->
            if error
                push_to_client(message.error(id:mesg.id, error:error))
            else
                push_to_client(message.account_settings_saved(id:mesg.id))


########################################
# User Feedback
########################################
report_feedback = (mesg, push_to_client, account_id) ->
    data = {}  # TODO -- put interesting info here
    database.report_feedback
        account_id  : account_id
        category    : mesg.category
        description : mesg.description
        data        : data
        nps         : mesg.nps
        cb          : (err, results) -> push_to_client(message.feedback_reported(id:mesg.id, error:err))

get_all_feedback_from_user = (mesg, push_to_client, account_id) ->
    if account_id == null
        push_to_client(message.all_feedback_from_user(id:mesg.id, error:true, data:to_json("User not signed in.")))
        return
    database.get_all_feedback_from_user
        account_id  : account_id
        cb          : (err, results) -> push_to_client(message.all_feedback_from_user(id:mesg.id, data:to_json(results), error:err))



#########################################
# Sending emails
#########################################

emailjs = require('emailjs')
email_server = null

# here's how I test this function:  require('hub').send_email(subject:'subject', body:'body', to:'wstein@gmail.com', cb:console.log)
exports.send_email = send_email = (opts={}) ->
    opts = defaults(opts,
        subject : required
        body    : required
        from    : 'salvusmath@gmail.com'
        to      : required
        cc      : ''
        cb      : undefined)

    async.series([
        (cb) ->
            if email_server == null
                filename = 'data/secrets/salvusmath_email_password'
                require('fs').readFile(filename, 'utf8', (error, password) ->
                    if error
                        winston.info("Unable to read the file '#{filename}', which is needed to send emails.")
                        opts.cb(error)
                    email_server  = emailjs.server.connect(
                       user     : "salvusmath"
                       password : password
                       host     : "smtp.gmail.com"
                       ssl      : true
                    )
                    cb()
                )
            else
                cb()
        (cb) ->
            email_server.send(
               text : opts.body
               from : opts.from
               to   : opts.to
               cc   : opts.cc
               subject : opts.subject,
            opts.cb)
            cb()
    ])






########################################
# Persistent Sage Sessions
########################################
persistent_sage_sessions = {}


SAGE_SESSION_LIMITS = {cputime:60, walltime:15*60, vmem:2000, numfiles:1000, quota:128}

create_persistent_sage_session = (mesg, account_id, push_to_client) ->
    winston.log('creating persistent sage session')
    # generate a uuid
    session_uuid = uuid.v4()
    # cap limits
    misc.min_object(mesg.limits, SAGE_SESSION_LIMITS)  # TODO
    database.random_sage_server( cb:(error, sage_server) ->
        # TODO: deal with case when there are no sage servers -- or when error is set !
        sage_conn = new sage.Connection(
            host:sage_server.host
            port:sage_server.port
            recv:(m) ->
                winston.info("(hub) persistent_sage_conn (#{session_uuid})-- recv(#{to_safe_str(m)})")
                switch m.event
                    when "output", "terminate_session"
                        m.session_uuid = session_uuid  # tag with session uuid
                        push_to_client(m)
                    when "session_description"
                        # record this for later use for signals:
                        persistent_sage_sessions[session_uuid].pid = m.pid
                        persistent_sage_sessions[session_uuid].account_id = account_id
                        push_to_client(message.session_started(id:mesg.id, session_uuid:session_uuid, limits:m.limits))
                    else
                        push_to_client(m)
            cb: ->
                winston.info("(hub) persistent_sage_conn -- connected.")
                # send message to server requesting parameters for this session
                sage_conn.send(mesg)
        )
        # Save sage_conn object so that when the user requests evaluation of
        # code in the session with this id, we use this.
        persistent_sage_sessions[session_uuid] = {conn:sage_conn}

        winston.info("(hub) added #{session_uuid} to persistent sessions")
    )

send_to_persistent_sage_session = (mesg, account_id) ->
    winston.debug("send_to_persistent_sage_session(#{to_safe_str(mesg)})")

    session_uuid = mesg.session_uuid
    session = persistent_sage_sessions[session_uuid]
    if session.account_id != account_id
        winston.info("(hub) attempt by account #{account_id} to execute code in session #{session_uuid} that it does not own.   This can only be the result of a bug or hack.")
        return

    if not session?
        winston.error("TODO -- session #{mesg.session_uuid} does not exist")
        return

    # modify the message so that it can be interpreted by sage server
    switch mesg.event
        when "send_signal"
            mesg.pid = session.pid

    if mesg.event == 'send_signal'   # other control messages would go here too
        # TODO: this function is a DOS vector, so we need to secure/limit it
        # Also, need to ensure that user is really allowed to do this action, whatever it is.
        sage.send_signal
            host   : session.conn.host
            port   : session.conn.port
            pid    : mesg.pid
            signal : mesg.signal
    else
        session.conn.send(mesg)


##########################################
# Stateless Sage Sessions
##########################################
stateless_exec_cache = null

init_stateless_exec = () ->
    stateless_exec_cache = database.key_value_store(name:'stateless_exec')

stateless_sage_exec = (input_mesg, output_message_callback) ->
    winston.info("(hub) stateless_sage_exec #{to_safe_str(input_mesg)}")
    exec_nocache = () ->
        output_messages = []
        stateless_sage_exec_nocache(input_mesg,
            (mesg) ->
                if mesg.event == "output"
                    output_messages.push(mesg)
                output_message_callback(mesg)
                if mesg.done and input_mesg.allow_cache
                    winston.info("caching result")
                    stateless_exec_cache.set(key:[input_mesg.code, input_mesg.preparse], value:output_messages)
        )
    if not input_mesg.allow_cache
        exec_nocache()
        return
    stateless_exec_cache.get(key:[input_mesg.code, input_mesg.preparse], cb:(err, output) ->
        if output?
            winston.info("(hub) -- using cache")
            for mesg in output
                mesg.id = input_mesg.id
                output_message_callback(mesg)
        else
            exec_nocache()
    )

stateless_sage_exec_fake = (input_mesg, output_message_callback) ->
    # test mode to eliminate all of the calls to sage_server time/overhead
    output_message_callback({"stdout":eval(input_mesg.code),"done":true,"event":"output","id":input_mesg.id})

stateless_exec_using_server = (input_mesg, output_message_callback, host, port) ->
    sage_conn = new sage.Connection(
        host:host
        port:port
        recv:(mesg) ->
            winston.info("(hub) sage_conn -- received message #{to_safe_str(mesg)}")
            output_message_callback(mesg)
        cb: ->
            winston.info("(hub) sage_conn -- sage: connected.")
            sage_conn.send(message.start_session(limits:{walltime:5, cputime:5, numfiles:1000, vmem:2048}))
            winston.info("(hub) sage_conn -- send: #{to_safe_str(input_mesg)}")
            sage_conn.send(input_mesg)
            sage_conn.send(message.terminate_session())
    )

stateless_sage_exec_nocache = (input_mesg, output_message_callback) ->
    winston.info("(hub) stateless_sage_exec_nocache #{to_safe_str(input_mesg)}")
    database.random_sage_server( cb:(err, sage_server) ->
        if sage_server?
            stateless_exec_using_server(input_mesg, output_message_callback, sage_server.host, sage_server.port)
        else
            winston.error("(hub) no sage servers!")
            output_message_callback(message.terminate_session(reason:'no Sage servers'))
    )


#############################################
# Start everything running
#############################################
exports.start_server = start_server = () ->
    # the order of init below is important
    init_http_server()
    winston.info("Using Cassandra keyspace #{program.keyspace}")
    database = new cass.Salvus(hosts:program.database_nodes.split(','), keyspace:program.keyspace)
    init_sockjs_server()
    init_stateless_exec()
    http_server.listen(program.port)
    winston.info("Started hub. HTTP port #{program.port}; TCP port #{program.tcp_port}; keyspace #{program.keyspace}")

#############################################
# Process command line arguments
#############################################
program.usage('[start/stop/restart/status] [options]')
    .option('-p, --port <n>', 'port to listen on (default: 5000)', parseInt, 5000)
    .option('-t, --tcp_port <n>', 'tcp port to listen on from other tornado servers (default: 5001)', parseInt, 5001)
    .option('-l, --log_level [level]', "log level (default: INFO) useful options include WARNING and DEBUG", String, "INFO")
    .option('--address [string]', 'address of interface to bind to (default: "127.0.0.1")', String, "127.0.0.1")
    .option('--pidfile [string]', 'store pid in this file (default: "data/pids/hub.pid")', String, "data/pids/hub.pid")
    .option('--logfile [string]', 'write log to this file (default: "data/logs/hub.log")', String, "data/logs/hub.log")
    .option('--database_nodes <string,string,...>', 'comma separated list of ip addresses of all database nodes in the cluster', String, 'localhost')
    .option('--keyspace [string]', 'Cassandra keyspace to use (default: "test")', String, 'test')
    .parse(process.argv)

if program._name == 'hub.js'
    # run as a server/daemon (otherwise, is being imported as a library)
    process.addListener "uncaughtException", (err) ->
        console.log("BUG ****************************************************************************")
        console.log("Uncaught exception: " + err)
        console.trace()
        console.log("BUG ****************************************************************************")

    daemon({pidFile:program.pidfile, outFile:program.logfile, errFile:program.logfile}, start_server)









