#################################################################
#
# storage -- a node.js program/library for interacting with
# the SageMath Cloud's ZFS-based replicated distributed snapshotted
# project storage system.
#
#################################################################

winston   = require 'winston'
HashRing  = require 'hashring'
rmdir     = require('rimraf')
fs        = require 'fs'
cassandra = require 'cassandra'
async     = require 'async'
misc      = require 'misc'
misc_node = require 'misc_node'
uuid      = require 'node-uuid'
_         = require 'underscore'
{defaults, required} = misc

# Set the log level to debug
winston.remove(winston.transports.Console)
winston.add(winston.transports.Console, level: 'debug')

SALVUS_HOME=process.cwd()
STORAGE_USER = 'storage'
STORAGE_TMP = '/home/storage/'
TIMEOUT = 7200  # 2 hours

# Connect to the cassandra database server; sets the global database variable.
database = undefined
connect_to_database = (cb) ->
    fs.readFile "#{SALVUS_HOME}/data/secrets/cassandra/hub", (err, password) ->
        if err
            cb(err)
        else
            new cassandra.Salvus
                hosts    : [if process.env.USER=='wstein' then 'localhost' else '10.1.3.2']  # TODO
                keyspace : if process.env.USER=='wstein' then 'test' else 'salvus'        # TODO
                username : if process.env.USER=='wstein' then 'salvus' else 'hub'         # TODO
                consistency : 1
                password : password.toString().trim()
                cb       : (err, db) ->
                    set_database(db, cb)

exports.set_database = set_database = (db, cb) ->
    database = db
    init_hashrings(cb)

exports.db = () -> database # TODO -- for testing

filesystem = (project_id) -> "projects/#{project_id}"
mountpoint = (project_id) -> "/projects/#{project_id}"
exports.username = username   = (project_id) -> project_id.replace(/-/g,'')

execute_on = (opts) ->
    opts = defaults opts,
        host        : required
        command     : required
        err_on_exit : true
        err_on_stderr : true     # if anything appears in stderr then set err=output.stderr, even if the exit code is 0.
        timeout     : TIMEOUT
        user        : STORAGE_USER
        cb          : undefined
    t0 = misc.walltime()
    misc_node.execute_code
        command     : "ssh"
        args        : ["-o StrictHostKeyChecking=no", "#{opts.user}@#{opts.host}", opts.command]
        timeout     : opts.timeout
        err_on_exit : opts.err_on_exit
        cb          : (err, output) ->
            if not err? and opts.err_on_stderr and output.stderr
                # strip out the ssh key warnings, which we'll get the first time connecting to hosts, and which are not errors.
                x = (y for y in output.stderr.split('\n') when (y.trim().lenth > 0 and y.indexOf('Warning') == -1 and y.indexOf('to the list of known hosts') == -1))
                if x.length > 0
                    err = output.stderr
            winston.debug("#{misc.walltime(t0)} seconds to execute '#{opts.command}' on #{opts.host}")
            opts.cb?(err, output)


######################
# Health/status
######################
###
# healthy and up  = "zpool list -H projects" responds like this within 5 seconds?
# projects        508G    227G    281G    44%     2.22x   ONLINE  -
# Or maybe check that "zpool import" isn't a running process?
salvus@compute11a:~$ ps ax |grep zpool
 1445 ?        S      0:00 sh -c zpool import -Nf projects; mkdir -p /projects; chmod a+rx /projects
 1446 ?        D      0:00 zpool import -Nf projects

or this since we don't need "sudo zpool":

    storage@compute11a:~$ sudo zfs list projects
    NAME       USED  AVAIL  REFER  MOUNTPOINT
    projects   148G   361G  4.92M  /projects
    salvus@cloud1:~$ sudo zfs list projects
    [sudo] password for salvus:
    cannot open 'projects': dataset does not exist

###

######################
# Database error logging
######################

exports.log_error = log_error = (opts) ->
    opts = defaults opts,
        project_id : required
        mesg       : required       # json-able
        cb         : undefined
    winston.debug("log_error(#{opts.project_id}): '#{misc.to_json(opts.mesg)}' to DATABASE")
    x = "errors_zfs['#{cassandra.now()}']"
    v = {}
    v[x] = misc.to_json(opts.mesg)
    database.update
        table : 'projects'
        where : {project_id : opts.project_id}
        set   : v
        cb    : (err) -> opts.cb?(err)


exports.get_errors = get_errors = (opts) ->
    opts = defaults opts,
        project_id : required       # string (a single id) or a list of ids
        max_age_s  : undefined      # if given, only return errors that are within max_age_s seconds of now.
        cb         : required       # cb(err, {project_id:[list,of,errors], ...}
    dbg = (m) -> winston.debug("get_errors: #{m}")
    if typeof(opts.project_id) == 'string'
        v = [opts.project_id]
    else
        v = opts.project_id
    dbg("v=#{misc.to_json(v)}")
    database.select
        table   : 'projects'
        where   : {project_id : {'in':v}}
        columns : ['project_id', 'errors_zfs']
        cb      : (err, results) ->
            if err
                opts.cb(err)
            else
                if opts.max_age_s?
                    cutoff = misc.mswalltime() - opts.max_age_s*1000
                    dbg("cutoff=#{cutoff}")
                    for entry in results
                        r = entry[1]
                        for time, mesg of r
                            d = new Date(time)
                            delete r[time]
                            if d.valueOf() >= cutoff
                                r[d.toISOString()] = misc.from_json(mesg)
                else
                    for entry in results
                        r = entry[1]
                        for time, mesg of r
                            delete r[time]
                            r[(new Date(time)).toISOString()] = misc.from_json(mesg)

                ans = {}
                for entry in results
                    if misc.len(entry[1]) > 0
                        ans[entry[0]] = entry[1]
                opts.cb(undefined, ans)



######################
# Running Projects
######################

# if user doesn't exist on the given host, create them
exports.create_user = create_user = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : required
        action     : 'create'   # 'create', 'kill' (kill all proceses), 'skel' (copy over skeleton), 'chown' (chown files)
        base_url   : ''         # used when writing info.json
        chown      : false      # if true, chowns files in /project/projectid in addition to creating user.
        timeout    : 200        # time in seconds
        cb         : undefined

    winston.info("creating user for #{opts.project_id} on #{opts.host}")
    execute_on
        host    : opts.host
        command : "sudo /usr/local/bin/create_project_user.py --#{opts.action} --base_url=#{opts.base_url} --host=#{opts.host} #{if opts.chown then '--chown' else ''} #{opts.project_id}"
        timeout : opts.timeout
        cb      : opts.cb

# Open project on the given host.  This mounts the project, ensures the appropriate
# user exists and that ssh-based login to that user works.
exports.open_project = open_project = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : required
        base_url   : ''
        chown      : false
        cb         : required   # cb(err, host used)

    winston.info("opening project #{opts.project_id} on #{opts.host}")
    dbg = (m) -> winston.debug("open_project(#{opts.project_id},#{opts.host}): #{m}")

    async.series([
        (cb) ->
            dbg("check that host is up and not still mounting the pool")
            execute_on
                host    : opts.host
                timeout : 10
                command : "pidof /sbin/zpool"
                err_on_exit : false
                err_on_stderr : false
                cb      : (err, output) ->
                    if err
                        dbg("host #{opts.host} appears down -- couldn't connect -- #{err}")
                        cb(err)
                    else
                        o = (output.stdout + output.stderr).trim()
                        if output.exit_code != 0 and o == ""
                            dbg("zpool not running on #{opts.host} -- ready to go.")
                            cb()
                        else
                            cb("zpool still being imported on #{opts.host} -- pid = #{o}")

        (cb) ->
            dbg("mount filesystem")
            execute_on
                host    : opts.host
                timeout : 15  # relatively small timeout due to zfs deadlocks -- just move onto another host
                command : "sudo zfs set mountpoint=#{mountpoint(opts.project_id)} #{filesystem(opts.project_id)}&&sudo zfs mount #{filesystem(opts.project_id)}"
                cb      : (err, output) ->
                    if err
                        if err.indexOf('directory is not empty') != -1
                            err += "mount directory not empty -- login to '#{opts.host}' and manually delete '#{mountpoint(opts.project_id)}'"
                            execute_on
                                host : opts.host
                                user : 'root'
                                command : "rm -rf '#{mountpoint(opts.project_id)}'"
                        else if err.indexOf('filesystem already mounted') != -1  or err.indexOf('cannot unmount') # non-fatal: to be expected if fs mounted/busy already
                            err = undefined
                    cb(err)
        (cb) ->
            dbg("create user")
            create_user
                project_id : opts.project_id
                action     : 'create'
                host       : opts.host
                base_url   : opts.base_url
                chown      : opts.chown
                cb         : cb
        (cb) ->
            dbg("copy over skeleton")
            create_user
                project_id : opts.project_id
                action     : 'skel'
                host       : opts.host
                base_url   : opts.base_url
                chown      : opts.chown
                cb         : cb
        (cb) ->
            dbg("test login")
            execute_on
                host    : opts.host
                timeout : 20
                user    : username(opts.project_id)
                command : "pwd"
                cb      : (err, output) ->
                    if err
                        cb(err)
                    else if output.stdout.indexOf(mountpoint(opts.project_id)) == -1
                        cb("failed to properly mount project")
                    else
                        cb()
    ], opts.cb)

# Current hostname of computer where project is currently opened.
exports.get_current_location = get_current_location = (opts) ->
    opts = defaults opts,
        project_id : required
        cb         : required      # cb(err, hostname or undefined); undefined if project not opened.
    winston.debug("getting location of #{opts.project_id} from database")
    database.select_one
        table   : 'projects'
        where   : {project_id : opts.project_id}
        json    : ['location']
        columns : ['location']
        cb      : (err, r) ->
            if r?[0]?
                # e.g., r = [{"host":"10.3.1.4","username":"c1f1dc4adbf04fc69878012020a0a829","port":22,"path":"."}]
                if r[0].username != username(opts.project_id)
                    winston.debug("get_current_location - WARNING: project #{opts.project_id} not yet fully migrated")
                    opts.cb(undefined, undefined)
                else
                    cur_loc = r[0]?.host
                    if cur_loc == ""
                        cur_loc = undefined
                    opts.cb(undefined, cur_loc)
            else
                opts.cb(err)


# Open the project on some host, if possible.  First, try the host listed in the location field
# in the database, if it is set.  If it isn't set, try other locations until success, trying
# the ones with the newest snasphot, breaking ties at random.
exports.open_project_somewhere = open_project_somewhere = (opts) ->
    opts = defaults opts,
        project_id : required
        base_url   : ''
        exclude    : undefined  # if project not currently opened, won't open on any host in the list exclude
        cb         : required   # cb(err, host used)

    dbg = (m) -> winston.debug("open_project_somewhere(#{opts.project_id}): #{m}")

    cur_loc   = undefined
    host_used = undefined
    hosts     = undefined
    async.series([
        (cb) ->
            dbg("get current location of project from database")
            get_current_location
                project_id : opts.project_id
                cb         : (err, x) ->
                    cur_loc = x
                    cb(err)
        (cb) ->
            if not cur_loc?
                dbg("no current location")
                # we'll try all other hosts in the next step
                cb()
            else
                dbg("trying to open at currently set location")
                open_project
                    project_id : opts.project_id
                    host       : cur_loc
                    base_url   : opts.base_url
                    cb         : (err) ->
                        if not err
                            host_used = cur_loc  # success!
                        else
                            dbg("nonfatal error attempting to open on #{cur_loc} -- #{err}")
                        cb()
        (cb) ->
            if host_used?  # done?
                cb(); return
            dbg("getting and sorting available hosts")
            get_snapshots
                project_id : opts.project_id
                cb         : (err, snapshots) ->
                    if err
                        cb(err)
                    else
                        # The Math.random() makes it so we randomize the order of the hosts with snapshots that tie.
                        # It's just a simple trick to code something that would otherwise be very awkward.
                        # TODO: This induces some distribution on the set of permutations, but I don't know if it is the
                        # uniform distribution (I only thought for a few seconds).  If not, fix it later.
                        v = ([snaps[0], Math.random(), host] for host, snaps of snapshots when snaps?.length >=1 and host != cur_loc)
                        v.sort()
                        v.reverse()

                        dbg("v = #{misc.to_json(v)}")
                        hosts = (x[2] for x in v)

                        if opts.exclude?
                            hosts = (x for x in hosts when opts.exclude.indexOf(x) == -1)

                        ## TODO: FOR TESTING -- restrict to Google
                        ##hosts = (x for x in hosts when x.slice(0,4) == '10.3')

                        dbg("hosts = #{misc.to_json(hosts)}")
                        cb()
        (cb) ->
            if host_used?  # done?
                cb(); return
            dbg("trying each possible host until one works -- hosts=#{misc.to_json(hosts)}")
            f = (host, c) ->
                if host_used?
                    c(); return
                dbg("trying to open project on #{host}")
                open_project
                    project_id : opts.project_id
                    host       : host
                    base_url   : opts.base_url
                    cb         : (err) ->
                        if not err
                            dbg("project worked on #{host}")
                            host_used = host
                        else
                            dbg("nonfatal error attempting to open on #{host}")
                        c()

            async.mapSeries(hosts, f, cb)
        (cb) ->
            if host_used? and host_used != cur_loc
                new_loc = {"host":host_used,"username":username(opts.project_id),"port":22,"path":"."}
                dbg("record location in database: #{misc.to_json(new_loc)}")
                database.update
                    table : 'projects'
                    set   : {location:new_loc}
                    json  : ['location']
                    where : {project_id : opts.project_id}
                    cb    : cb
            else
                cb()
    ], (err) ->
        if err
            opts.cb(err)
        else
            if not host_used?
                opts.cb("unable to find any host on which to run #{opts.project_id} -- all failed")
            else
                opts.cb(undefined, host_used)
    )


exports.close_project = close_project = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : undefined  # defaults to current host, if deployed
        unset_loc  : true       # set location to undefined in the database
        cb         : required

    if not opts.host?
        use_current_host(close_project, opts)
        return

    winston.info("close project #{opts.project_id} on #{opts.host}")
    dbg = (m) -> winston.debug("close_project(#{opts.project_id},#{opts.host}): #{m}")

    user = username(opts.project_id)
    async.series([
        (cb) ->
            dbg("killing all processes")
            create_user
                project_id : opts.project_id
                host       : opts.host
                action     : 'kill'
                timeout    : 30
                cb         : cb
        (cb) ->
            dbg("unmount filesystem")
            execute_on
                host    : opts.host
                timeout : 30
                command : "sudo zfs set mountpoint=none #{filesystem(opts.project_id)}&&sudo zfs umount #{mountpoint(opts.project_id)}"
                cb      : (err, output) ->
                    if err
                        if err.indexOf('not currently mounted') != -1 or err.indexOf('not a ZFS filesystem') != -1   # non-fatal: to be expected (due to using both mountpoint setting and umount)
                            err = undefined
                    cb(err)
        (cb) ->
            if opts.unset_loc
                database.update
                    table : 'projects'
                    set   : {location:undefined}
                    where : {project_id : opts.project_id}
                    cb    : cb
            else
                cb()
    ], opts.cb)

# Call "close_project" (with unset_loc=true) on all projects that have been open for
# more than ttl seconds, where opened means that location is set.
exports.close_stale_projects = (opts) ->
    opts = defaults opts,
        ttl     : 60*60*24   # time in seconds (up to a week)
        dry_run : true       # don't actually close the projects
        limit   : 20         # number of projects to close simultaneously.
        cb      : required

    projects = undefined
    async.series([
        (cb) ->
            database.stale_projects
                ttl : opts.ttl
                cb  : (err, v) ->
                    projects = v
                    cb(err)
        (cb) ->
            f = (x, cb) ->
                project_id = x.project_id
                host       = x.location.host
                winston.debug("close stale project #{project_id} at #{host}")
                if opts.dry_run
                    cb()
                else
                    # would actually close
                    close_project
                        project_id : project_id
                        host       : host
                        unset_loc  : true
                        cb         : cb
            async.eachLimit(projects, opts.limit, f, cb)
    ], opts.cb)


# Creates project with given id on exactly one (random) available host, and
# returns that host.  This also snapshots the projects, which puts it in the
# database.  It does not replicate the project out to all hosts.
exports.create_project = create_project = (opts) ->
    opts = defaults opts,
        project_id : required
        quota      : '5G'
        base_url   : ''
        chown      : false       # if true, chown files in filesystem (throw-away: used only for migration from old)
        exclude    : []          # hosts to not use
        unset_loc  : true
        cb         : required    # cb(err, host)   where host=ip address of a machine that has the project.

    dbg = (m) -> winston.debug("create_project(#{opts.project_id}): #{m}")

    dbg("check if the project filesystem already exists somewhere")
    get_hosts
        project_id : opts.project_id
        cb         : (err, hosts) ->
            if err
                opts.cb(err); return

            if hosts.length > 0
                if opts.exclude.length > 0
                    hosts = (h for h in hosts when opts.exclude.indexOf(h) == -1)
                if hosts.length > 0
                    opts.cb(undefined, hosts[0])
                    return

            dbg("according to DB, the project filesystem doesn't exist anywhere (allowed), so let's make it somewhere...")
            locs = _.flatten(locations(project_id:opts.project_id))

            if opts.exclude.length > 0
                locs = (h for h in locs when opts.exclude.indexOf(h) == -1)

            dbg("try each host in locs (in random order) until one works")
            done       = false
            fs         = filesystem(opts.project_id)
            host       = undefined
            mounted_fs = false
            errors     = {}

            f = (i, cb) ->  # try ith one (in random order)!
                if done
                    cb(); return
                host = misc.random_choice(locs)
                dbg("try to allocate project on #{host} (this is attempt #{i+1})")
                misc.remove(locs, host)
                async.series([
                    (c) ->
                        dbg("creating ZFS filesystem")
                        execute_on
                            host    : host
                            command : "sudo zfs create #{fs} ; sudo zfs set snapdir=hidden #{fs} ; sudo zfs set quota=#{opts.quota} #{fs} ; sudo zfs set mountpoint=#{mountpoint(opts.project_id)} #{fs}"
                            timeout : 30
                            cb      : (err, output) ->
                                if output?.stderr?.indexOf('dataset already exists') != -1
                                    # non-fatal
                                    err = undefined
                                if not err
                                    mounted_fs = true
                                c(err)
                    (c) ->
                        dbg("created fs successfully; now create user")
                        create_user
                            project_id : opts.project_id
                            host       : host
                            action     : 'create'
                            chown      : opts.chown
                            timeout    : 30
                            cb         : c
                    (c) ->
                        dbg("copy over the template files, e.g., .sagemathcloud")
                        create_user
                            project_id : opts.project_id
                            action     : 'skel'
                            host       : host
                            timeout    : 30
                            cb         : c
                    (c) ->
                        dbg("snapshot the project")
                        snapshot
                            project_id : opts.project_id
                            host       : host
                            force      : true
                            cb         : c
                ], (err) ->
                    async.series([
                        (c) ->
                            if mounted_fs
                                # unmount the project on this host (even if something along the way failed above)
                                close_project
                                    project_id : opts.project_id
                                    host       : host
                                    unset_loc  : opts.unset_loc
                                    cb         : (ignore) -> c()
                            else
                                c()
                        (c) ->
                            if err
                                dbg("error #{host} -- #{err}")
                                errors[host] = err
                            else
                                done = true
                            c()
                    ], () -> cb())
                )

            async.mapSeries [0...locs.length], f, () ->
                if done
                    opts.cb(undefined, host)
                else
                    if misc.len(errors) == 0
                        opts.cb()
                    else
                        opts.cb(errors)






######################
# Managing Projects
######################


exports.quota = quota = (opts) ->
    opts = defaults opts,
        project_id : required
        size       : undefined    # if given, first sets the quota
        host       : undefined    # if given, only operate on the given host; otherwise operating on all hosts of the project (and save in database if setting)
        cb         : undefined    # cb(err, quota in bytes)
    winston.info("quota -- #{misc.to_json(opts)}")

    dbg = (m) -> winston.debug("quota (#{opts.project_id}): #{m}")

    if not opts.host?
        hosts   = undefined
        results = undefined
        size    = undefined
        async.series([
            (cb) ->
                dbg("get list of hosts")
                get_hosts
                    project_id : opts.project_id
                    cb         : (err, h) ->
                        hosts = h
                        if not err and hosts.length == 0
                            err = 'no hosts -- quota not defined'
                        cb(err)
            (cb) ->
                dbg("#{if opts.size then 'set' else 'compute'} quota on all hosts: #{misc.to_json(hosts)}")
                f = (host, c) ->
                    quota
                        project_id : opts.project_id
                        size       : opts.size
                        host       : host
                        cb         : c
                async.map hosts, f, (err, r) ->
                    results = r
                    cb(err)
            (cb) ->
                if opts.size?
                    size = opts.size
                    cb()
                    return
                dbg("checking that all quotas consistent...")
                size = misc.max(results)
                if misc.min(results) == size
                    cb()
                else
                    winston.info("quota (#{opts.project_id}): self heal -- quota discrepancy, now self healing to max size (=#{size})")
                    f = (i, c) ->
                        host = hosts[i]
                        if results[i] >= size
                            # already maximal, so no need to set it
                            c()
                        else
                            quota
                                project_id : opts.project_id
                                size       : size
                                host       : host
                                cb         : c
                    async.map([0...hosts.length], f, cb)
            (cb) ->
                dbg("saving in database")
                database.update
                    table : 'projects'
                    where : {project_id : opts.project_id}
                    set   : {'quota_zfs':"#{size}"}
                    cb    : cb
        ], (err) ->
            opts.cb?(err, size)
        )
        return

    if not opts.size?
        dbg("getting quota on #{opts.host}")
        execute_on
            host       : opts.host
            command    : "sudo zfs get -pH -o value quota #{filesystem(opts.project_id)}"
            cb         : (err, output) ->
                if not err
                    size = output.stdout
                    size = parseInt(size)
                opts.cb?(err, size)
    else
        dbg("setting quota on #{opts.host} to #{opts.size}")
        execute_on
            host       : opts.host
            command    : "sudo zfs set quota=#{opts.size} #{filesystem(opts.project_id)}"
            cb         : (err, output) ->
                opts.cb?(err, opts.size)

# Find a host for this project that has the most recent snapshot
exports.updated_host = updated_host = (opts) ->
    opts = defaults opts,
        project_id : required
        cb         : required   # cb(err, hostname)

    get_snapshots
        project_id : opts.project_id
        cb         : (err, snapshots) ->
            if not err and snapshots.length == 0
                err = "project doesn't have any data"
            if err
                opts.cb(err)
                return
            v = ([val[0],host] for host, val of snapshots)
            v.sort()
            host = v[v.length-1][1]
            opts.cb(undefined, host)


exports.get_usage = get_usage = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : undefined  # if not given, choos any node with newest snapshot
        cb         : required   # cb(err, {avail:?, used:?, usedsnap:?})  # ? are strings like '17M' or '13G' as output by zfs.  NOT bytes.
                                # on success, the quota field in the database for the project is set as well
    usage = undefined
    dbg = (m) -> winston.debug("get_usage (#{opts.project_id}): #{m}")

    async.series([
        (cb) ->
            if opts.host?
                cb()
            else
                dbg("determine host")
                updated_host
                    project_id : opts.project_id
                    cb         : (err, host) ->
                        opts.host = host
                        cb(err)
        (cb) ->
            dbg("getting usage on #{opts.host}")
            execute_on
                host    : opts.host
                command : "sudo zfs list -H -o avail,used,usedsnap #{filesystem(opts.project_id)}"
                cb      : (err, output) ->
                    if err
                        cb(err)
                    else
                        v = output.stdout.split('\t')
                        usage = {avail:v[0].trim(), used:v[1].trim(), usedsnap:v[2].trim()}
                        cb()
        (cb) ->
            dbg("updating database with usage = #{usage}")
            database.update
                table : 'projects'
                where : {project_id : opts.project_id}
                set   : {'usage_zfs':usage}
                json  : ['usage_zfs']
                cb    : cb
    ], (err) -> opts.cb?(err, usage))





######################
# Snapshotting
######################

# set opts.host to the currently deployed host, then do f(opts).
# If project not currently deployed, do nothing.
use_current_host = (f, opts) ->
    if opts.host?
        throw("BUG! -- should never call use_best_host with host already set -- infinite recurssion")
    get_current_location
        project_id : opts.project_id
        cb         : (err, host) ->
            if err
                opts.cb(err)
            else if host?
                opts.host = host
                f(opts)
            else
                # no current host -- nothing to do
                opts.cb?()

# Set opts.host to the best host, where best = currently deployed, or if project isn't deployed,
# it means a randomly selected host with the newest snapshot.  Then does f(opts).
use_best_host = (f, opts) ->
    dbg = (m) -> winston.debug("use_best_host(#{misc.to_json(opts)}): #{m}")
    dbg()

    if opts.host?
        throw("BUG! -- should never call use_best_host with host already set -- infinite recurssion")
    snapshots = undefined
    async.series([
        (cb) ->
            get_current_location
                project_id : opts.project_id
                cb         : (err, host) ->
                    if err
                        cb(err)
                    else if host?
                        dbg("using currently deployed host")
                        opts.host = host
                        cb()
                    else
                        dbg("no current deployed host -- choose best one")
                        cb()
        (cb) ->
            if opts.host?
                cb(); return
            get_snapshots
                project_id : opts.project_id
                cb         : (err, x) ->
                    snapshots = x
                    cb(err)
        (cb) ->
            if opts.host?
                cb(); return
            # The Math.random() makes it so we randomize the order of the hosts with snapshots that tie.
            # It's just a simple trick to code something that would otherwise be very awkward.
            # TODO: This induces some distribution on the set of permutations, but I don't know if it is the
            # uniform distribution (I only thought for a few seconds).  If not, fix it later.
            v = ([snaps[0], Math.random(), host] for host, snaps of snapshots when snaps?.length >=1 and host != cur_loc)
            v.sort()
            v.reverse()
            hosts = (x[2] for x in v)

            host = hosts[0]
            if not host?
                cb("no available host")
            else
                dbg("using host = #{misc.to_json(host)}")
                opts.host = host
                cb()
    ], (err) ->
        if err
            opts.cb(err)
        else if opts.host?
            f(opts)
        else
            opts.cb("no available host")
    )

# Compute the time of the "probable last snapshot" in seconds since the epoch in UTC,
# or undefined if there are no snapshots.
exports.last_snapshot = last_snapshot = (opts) ->
    opts = defaults opts,
        project_id : required
        cb         : undefined    # cb(err, utc_seconds_epoch)
    database.select_one
        table      : 'projects'
        where      : {project_id : opts.project_id}
        columns    : ['last_snapshot']
        cb         : (err, r) ->
            if err
                opts.cb(err)
            else
                if not r? or not r[0]?
                    opts.cb(undefined, undefined)
                else
                    opts.cb(undefined, r[0]/1000)


# Make a snapshot of a given project on a given host and record
# this in the database; also record in the database the list of (interesting) files
# that changed in this snapshot (from the last one), according to diff.
exports.snapshot = snapshot = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : undefined    # if not given, use current location (if deployed; if not deployed does nothing)
        tag        : undefined
        force      : false        # if false (the default), don't make the snapshot if diff outputs empty list of files
                                  # (note that diff ignores ~/.*), and also don't make a snapshot if one was made within
        min_snapshot_interval_s : 90    # opts.min_snapshot_interval_s seconds.
        wait_for_replicate : false
        cb         : undefined

    if not opts.host?
        use_current_host(snapshot, opts)
        return

    dbg = (m) -> winston.debug("snapshot(#{opts.project_id},#{opts.host},force=#{opts.force}): #{m}")

    dbg()

    if opts.tag?
        tag = '-' + opts.tag
    else
        tag = ''
    now = misc.to_iso(new Date())
    name = filesystem(opts.project_id) + '@' + now + tag
    async.series([
        (cb) ->
            if opts.force
                cb()
            else
                dbg("get last mod time")
                database.select_one
                    table      : 'projects'
                    where      : {project_id : opts.project_id}
                    columns    : ['last_snapshot']
                    cb         : (err, r) ->
                        if err
                            cb(err)
                        else
                            x = r[0]
                            if not x?
                                cb()
                            else
                                d = new Date(x)
                                time_since_s = (new Date() - d)/1000
                                if time_since_s < opts.min_snapshot_interval_s
                                    cb('delay')
                                else
                                    cb()
        (cb) ->
            if opts.force
                cb(); return
            dbg("get the diff")
            diff
                project_id : opts.project_id
                host       : opts.host
                cb         : (err, modified_files) ->
                    if err
                        cb(err); return
                    if modified_files.length == 0
                        cb('delay')
                    else
                        cb()
        (cb) ->
            dbg("make snapshot")
            execute_on
                host    : opts.host
                command : "sudo zfs snapshot #{name}"
                timeout : 10
                cb      : cb
        (cb) ->
            dbg("record in database that we made a snapshot")
            record_snapshot_in_db
                project_id     : opts.project_id
                host           : opts.host
                name           : now + tag
                cb             : cb
        (cb) ->
            dbg("record when we made this recent snapshot (might be slightly off if multiple snapshots at once)")
            database.update
                table : 'projects'
                where : {project_id : opts.project_id}
                set   : {last_snapshot : now}
                cb    : cb
        (cb) ->
            if opts.wait_for_replicate
                dbg("replicate -- holding up return")
                replicate
                    project_id : opts.project_id
                    cb         : cb
            else
                dbg("replicate in the background (returning anyways)")
                cb()
                replicate
                    project_id : opts.project_id
                    cb         : (err) -> # ignore
    ], (err) ->
        if err == 'delay'
            opts.cb?()
        else
            opts.cb?(err)
    )

exports.get_snapshots = get_snapshots = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : undefined
        cb         : required
    database.select_one
        table   : 'projects'
        columns : ['locations']
        where   : {project_id : opts.project_id}
        cb      : (err, result) ->
            if err
                opts.cb(err)
                return
            result = result[0]
            if opts.host?
                if not result?
                    opts.cb(undefined, [])
                else
                    v = result[opts.host]
                    if v?
                        v = JSON.parse(v)
                    else
                        v = []
                    opts.cb(undefined, v)
            else
                ans = {}
                for k, v of result
                    ans[k] = JSON.parse(v)
                opts.cb(undefined, ans)

# Compute list of all hosts that actually have some version of the project.
# WARNING: returns an empty list if the project doesn't exist in the database!  *NOT* an error.
exports.get_hosts = get_hosts = (opts) ->
    opts = defaults opts,
        project_id : required
        cb         : required  # cb(err, [list of hosts])
    get_snapshots
        project_id : opts.project_id
        cb         : (err, snapshots) ->
            if err
                opts.cb(err)
            else
                opts.cb(undefined, (host for host, snaps of snapshots when snaps?.length > 0))

exports.record_snapshot_in_db = record_snapshot_in_db = (opts) ->
    opts = defaults opts,
        project_id     : required
        host           : required
        name           : required
        remove         : false
        cb             : undefined

    dbg = (m) -> winston.debug("record_snapshot_in_db(#{opts.project_id},#{opts.host},#{opts.name}): #{m}")

    new_snap_list = undefined
    async.series([
        (cb) ->
            dbg("get snapshots")
            get_snapshots
                project_id : opts.project_id
                host       : opts.host
                cb         : (err, v) ->
                    if err
                        cb(err)
                    else
                        if opts.remove
                            try
                                misc.remove(v, opts.name)
                            catch
                                # snapshot not in db anymore; nothing to do.
                                return
                        else
                            v.unshift(opts.name)
                        new_snap_list = v
                        cb()
        (cb) ->
            dbg("set new snapshots list")
            if not new_snap_list?
                cb(); return
            set_snapshots_in_db
                project_id : opts.project_id
                host       : opts.host
                snapshots  : new_snap_list
                cb         : cb
    ], (err) -> opts.cb?(err))

# Set the list of snapshots for a given project.  The
# input list is assumed sorted in reverse order (so newest first).
set_snapshots_in_db = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : required
        snapshots  : required
        cb         : undefined
    winston.debug("setting snapshots for #{opts.project_id} to #{misc.to_json(opts.snapshots).slice(0,100)}...")

    x = "locations['#{opts.host}']"

    if opts.snapshots.length == 0
        # deleting it
        database.delete
            thing : x
            table : 'projects'
            where : {project_id : opts.project_id}
            cb    : opts.cb
        return

    v = {}
    v[x] = JSON.stringify(opts.snapshots)
    database.update
        table : 'projects'
        where : {project_id : opts.project_id}
        set   : v
        cb    : opts.cb

# Connect to host, find out the snapshots, and put the definitely
# correct ordered (newest first) list in the database.
exports.repair_snapshots_in_db = repair_snapshots_in_db = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : undefined   # use "all" for **all** possible hosts on the whole cluster
        cb         : undefined
    if not opts.host? or opts.host == 'all'
        hosts = undefined
        async.series([
            (cb) ->
                if opts.host == 'all'
                    hosts = all_hosts
                    cb()
                else
                    # repair on all hosts that are "reasonable", i.e., anything in the db now.
                    get_hosts
                        project_id : opts.project_id
                        cb         : (err, r) ->
                            hosts = r
                            cb(err)
            (cb) ->
                f = (host, cb) ->
                    repair_snapshots_in_db
                        project_id : opts.project_id
                        host       : host
                        cb         : cb
                async.map(hosts, f, cb)
        ], (err) -> opts.cb?(err))
        return

    # other case -- a single host.

    snapshots = []
    f = filesystem(opts.project_id)
    async.series([
        (cb) ->
            # 1. get list of snapshots
            execute_on
                host    : opts.host
                command : "sudo zfs list -r -t snapshot -o name -s creation #{f}"
                timeout : 600
                cb      : (err, output) ->
                    if err
                        if output?.stderr? and output.stderr.indexOf('not exist') != -1
                            # entire project deleted from this host.
                            winston.debug("filesystem was deleted from #{opts.host}")
                            cb()
                        else
                            cb(err)
                    else
                        n = f.length
                        for x in output.stdout.split('\n')
                            x = x.slice(n+1)
                            if x
                                snapshots.unshift(x)
                        cb()
        (cb) ->
            # 2. put in database
            set_snapshots_in_db
                project_id : opts.project_id
                host       : opts.host
                snapshots  : snapshots
                cb         : cb
    ], (err) -> opts.cb?(err))


# Destroy snapshot of a given project on one or all hosts that have that snapshot,
# according to the database.  Updates the database to reflect success.
exports.destroy_snapshot = destroy_snapshot = (opts) ->
    opts = defaults opts,
        project_id : required
        name       : required      # typically 'timestamp[-tag]' but could be anything... BUT DON'T!
        host       : undefined     # if not given, attempts to delete snapshot on all hosts
        cb         : undefined

    if not opts.host?
        get_snapshots
            project_id : opts.project_id
            cb         : (err, snapshots) ->
                if err
                    opts.cb?(err)
                else
                    f = (host, cb) ->
                        destroy_snapshot
                            project_id : opts.project_id
                            name       : opts.name
                            host       : host
                            cb         : cb
                    v = (k for k, s of snapshots when s.indexOf(opts.name) != -1)
                    async.each(v, f, (err) -> opts.cb?(err))
        return

    async.series([
        (cb) ->
            # 1. delete snapshot
            execute_on
                host    : opts.host
                command : "sudo zfs destroy #{filesystem(opts.project_id)}@#{opts.name}"
                timeout : 600
                cb      : (err, output) ->
                    if err
                        if output?.stderr? and output.stderr.indexOf('could not find any snapshots to destroy')
                            err = undefined
                    cb(err)
        (cb) ->
            # 2. success -- so record in database that snapshot was *deleted*
            record_snapshot_in_db
                project_id : opts.project_id
                host       : opts.host
                name       : opts.name
                remove     : true
                cb         : cb
    ], (err) -> opts.cb?(err))


# WARNING: this function is very, very, very SLOW -- often 15-30 seconds, easily.
# Hence it is really not suitable to use for anything realtime.
exports.zfs_diff = zfs_diff = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : undefined   # undefined = currently deployed location; if not deployed, chooses one
        snapshot1  : required
        snapshot2  : undefined   # if undefined, compares with live filesystem
                                 # when defined, compares two diffs, which may be be VERY slow (e.g., 30 seconds) if
                                 # info is not available in the database.
        timeout    : 300
        cb         : required    # cb(err, list of filenames)

    dbg = (m) -> winston.debug("diff(#{misc.to_json(opts)}): #{m}")

    if not opts.host?
        use_best_host(zfs_diff, opts)
        return

    fs = filesystem(opts.project_id)
    two = if opts.snapshot2? then "#{fs}@#{opts.snapshot1}" else fs

    execute_on
        host    : opts.host
        command : "sudo zfs diff -H #{fs}@#{opts.snapshot1} #{two}"
        timeout : opts.timeout
        cb      : (err, output) ->
            if err
                opts.cb(err)
            else
                n = mountpoint(opts.project_id).length + 1
                a = []
                for h in output.stdout.split('\n')
                    v = h.split('\t')[1]
                    if v?
                        a.push(v.slice(n))
                opts.cb(undefined, a)


# Returns a list of files/paths that changed between live and the most recent snapshot.
# If host is given, it is treated as live.
# Returns empty list if project not deployed.
exports.diff = diff = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : undefined
        timeout    : 10
        cb         : required    # cb(err, list of filenames)

    host = opts.host
    v = []
    async.series([
        (cb) ->
            if host?
                cb()
            else
                get_current_location
                    project_id : opts.project_id
                    cb         : (err, _host) ->
                        if err
                            cb(err)
                        else
                            host = host
                            cb()
        (cb) ->
            if not host?
                cb(); return
            # use find command, which is thousands of times faster than "zfs diff".
            execute_on
                host    : host
                user    : username(opts.project_id)
                command : "find . -xdev -newermt \"`ls -1 ~/.zfs/snapshot|tail -1 | sed 's/T/ /g'`\" | grep -v '^./\\.'"
                timeout : opts.timeout  # this should be really fast
                cb      : (err, output) ->
                    if err and output?.stderr == ''
                        # if the list is empty, grep yields a nonzero error code.
                        err = undefined
                    winston.debug("#{err}, #{misc.to_json(output)}")
                    if err
                        cb(err)
                    else
                        for h in output.stdout.split('\n')
                            a = h.slice(2)
                            if a
                                v.push(a)
                        cb()
        ], (err) -> opts.cb(err, v))




exports.snapshot_listing = snapshot_listing = (opts) ->
    opts = defaults opts,
        project_id      : required
        timezone_offset : 0   # difference in minutes:  UTC - local_time
        path            : ''  # '' or a day in the format '2013-12-20'
        host            : undefined
        cb              : opts.cb

    dbg = (m) -> winston.debug("snapshot_listing(#{opts.project_id}): #{m}")
    dbg(misc.to_json(opts))

    if not opts.host?
        dbg("use current host")
        use_current_host(snapshot_listing, opts)
        return

    snaps = (cb) ->
        get_snapshots
            project_id : opts.project_id
            host       : opts.host
            cb         : (err, snapshots) ->
                if err
                    cb(err)
                else
                    cb(undefined, new Date( (new Date(x+"+0000")) - opts.timezone_offset*60*1000) for x in snapshots)

    if opts.path.length<10
        dbg("sorted list of unique days in local time, but as a file listing.")
        snaps (err, s) ->
            if err
                opts.cb(err); return
            s = (x.toISOString().slice(0,10) for x in s)
            s = _.uniq(s)
            s.sort()
            s.reverse()
            dbg("result=#{misc.to_json(s)}")
            opts.cb(undefined, s)
    else if opts.path.length == 10
        dbg("snapshots for a particular day in local time")
        snaps (err, s) ->
            if err
                opts.cb(err); return
            s = (x.toISOString().slice(0,19) for x in s)
            s = (x.slice(11) for x in s when x.slice(0,10) == opts.path)
            s = _.uniq(s)
            s.sort()
            s.reverse()
            dbg("result=#{misc.to_json(s)}")
            opts.cb(undefined, s)
    else
        opts.cb("not implemented")



######################
# Replication
######################

hashrings = undefined
topology = undefined
all_hosts = []
exports.init_hashrings = init_hashrings = (cb) ->
    database.select
        table   : 'storage_topology'
        columns : ['data_center', 'host', 'vnodes']
        cb      : (err, results) ->
            if err
                cb(err); return
            topology = {}
            for r in results
                datacenter = r[0]; host = r[1]; vnodes = r[2]
                if not topology[datacenter]?
                    topology[datacenter] = {}
                topology[datacenter][host] = {vnodes:vnodes}
                all_hosts.push(host)
            winston.debug(misc.to_json(topology))
            hashrings = {}
            for dc, obj of topology
                hashrings[dc] = new HashRing(obj)
            cb?()

exports.locations = locations = (opts) ->
    opts = defaults opts,
        project_id : required
        number     : 2         # number per data center to return

    return (ring.range(opts.project_id, opts.number) for dc, ring of hashrings)

# Replicate = attempt to make it so that the newest snapshot of the project
# is available on all copies of the filesystem.
# This code right now assumes all snapshots are of the form "timestamp[-tag]".
exports.replicate = replicate = (opts) ->
    opts = defaults opts,
        project_id : required
        cb         : undefined

    snaps   = undefined
    source  = undefined

    targets = locations(project_id:opts.project_id)
    num_replicas = targets[0].length

    snapshots = undefined

    versions = []   # will be list {host:?, version:?} of out-of-date objs, grouped by data center.

    new_project = false
    clear_replicating_lock = false
    errors = {}
    async.series([
        (cb) ->
            # check for lock
            database.select_one
                table   : 'projects'
                where   : {project_id : opts.project_id}
                columns : ['replicating']
                cb      : (err, r) ->
                    if err
                        cb(err)
                    else if r[0]
                        cb("already replicating")
                    else
                        # create lock
                        clear_replicating_lock = true
                        database.update
                            table : 'projects'
                            ttl   : 300
                            where : {project_id : opts.project_id}
                            set   : {'replicating': true}
                            cb    : (err) ->
                                cb(err)
        (cb) ->
            # Determine information about all known snapshots
            # of this project, and also the best source for
            # replicating out (which might not be one of the
            # locations determined by the hash ring).
            tm = misc.walltime()
            get_snapshots
                project_id : opts.project_id
                cb         : (err, result) ->
                    if err
                        cb(err)
                    else
                        if not result? or misc.len(result) == 0
                            # project doesn't have any snapshots at all or location.
                            # this could happen for a new project with no data, or one not migrated.
                            winston.debug("WARNING: project #{opts.project_id} has no snapshots")
                            new_project = true
                            cb(true)
                            return

                        snapshots = result
                        snaps = ([s[0], h] for h, s of snapshots)
                        snaps.sort()
                        x = snaps[snaps.length - 1]
                        ver = x[0]
                        source = {version:ver, host:x[1]}
                        # determine version of each target
                        for k in targets
                            v = []
                            for host in k
                                v.push({version:snapshots[host]?[0], host:host})
                            if v.length > 0
                                versions.push(v)
                        winston.debug("replicate (time=#{misc.walltime(tm)})-- status: #{misc.to_json(versions)}")
                        cb()
       (cb) ->
            # STAGE 1: do inter-data center replications so each data center contains at least one up to date node
            f = (d, cb) ->
                # choose newest in the datacenter -- this one is easiest to get up to date
                dest = d[0]
                for i in [1...d.length]
                    if d[i].version > dest.version
                        dest = d[i]
                if source.version == dest.version
                    cb() # already done
                else
                    send
                        project_id : opts.project_id
                        source     : source
                        dest       : dest
                        cb         : (err) ->
                            if not err
                                # means that we succeeded in the version update; record this so that
                                # the code in STAGE 2 below works.
                                dest.version = source.version
                            else
                                errors["src-#{source.host}-dest-#{dest.host}"] = err
                            cb()
            async.map(versions, f, cb)

       (cb) ->
            # STAGE 2: do intra-data center replications to get all data in each data center up to date.
            f = (d, cb) ->
                # choose last *newest* in the datacenter as source
                src = d[0]
                for i in [1...d.length]
                    if d[i].version > src.version
                        src = d[i]
                # crazy-looking nested async maps because we're writing this to handle
                # having more than 2 replicas per data center, though I have no plans
                # to actually do that.
                g = (dest, cb) ->
                    if src.version == dest.version
                        cb()
                    else
                        send
                            project_id : opts.project_id
                            source     : src
                            dest       : dest
                            cb         : (err) ->
                                if err
                                    errors["src-#{src.host}-dest-#{dest.host}"] = err
                                cb()
                async.map(d, g, cb)

            async.map(versions, f, cb)

    ], () ->
        if misc.len(errors) > 0
            err = errors
        else
            err = undefined
        if clear_replicating_lock
            # remove lock
            database.update
                table : 'projects'
                where : {project_id : opts.project_id}
                set   : {'replicating': false}
                cb    : () ->
                    if new_project
                        opts.cb?()
                    else
                        opts.cb?(err)
        else
           opts.cb?(err)

    )

exports.send = send = (opts) ->
    opts = defaults opts,
        project_id : required
        source     : required    # {host:ip_address, version:snapshot_name}
        dest       : required    # {host:ip_address, version:snapshot_name}
        force      : true
        cb         : undefined

    dbg = (m) -> winston.debug("send(#{opts.project_id},#{misc.to_json(opts.source)}-->#{misc.to_json(opts.dest)}): #{m}")

    dbg("sending")

    if opts.source.version == opts.dest.version
        dbg("trivial special case")
        opts.cb()
        return

    tmp = "#{STORAGE_TMP}/.storage-#{opts.project_id}-src-#{opts.source.host}-#{opts.source.version}-dest-#{opts.dest.host}-#{opts.dest.version}.lz4"
    f = filesystem(opts.project_id)
    clean_up = false
    async.series([
        (cb) ->
            dbg("check for already-there dump file")
            execute_on
                host    : opts.source.host
                command : "ls #{tmp}"
                timeout : 120
                err_on_exit : false
                cb      : (err, output) ->
                    if err
                        cb(err)
                    else if output.exit_code == 0
                        # file exists!
                        cb("file #{tmp} already exists on #{opts.source.host}")
                    else
                        # good to go
                        cb()
        (cb) ->
            dbg("dump range of snapshots")
            start = if opts.dest.version then "-i #{f}@#{opts.dest.version}" else ""
            clean_up = true
            execute_on
                host    : opts.source.host
                command : "sudo zfs send -RD #{start} #{f}@#{opts.source.version} | lz4c -  > #{tmp}"
                cb      : (err, output) ->
                    winston.debug(output)
                    cb(err)
        (cb) ->
            dbg("scp to destination")
            execute_on
                host    : opts.source.host
                command : "scp -o StrictHostKeyChecking=no #{tmp} #{STORAGE_USER}@#{opts.dest.host}:#{tmp}; echo ''>#{tmp}"
                cb      :  (err, output) ->
                    winston.debug(output)
                    cb(err)
        (cb) ->
            dbg("receive on destination side")
            force = if opts.force then '-F' else ''
            execute_on
                host    : opts.dest.host
                command : "cat #{tmp} | lz4c -d - | sudo zfs recv #{force} #{f}; rm #{tmp}"
                cb      : (err, output) ->
                    #winston.debug("(non-fatal) -- #{misc.to_json(output)}")
                    if output?.stderr
                        if output.stderr.indexOf('destination has snapshots') != -1
                            # this is likely caused by the database being stale regarding what snapshots are known,
                            # so we run a repair so that next time it will work.
                            dbg("probably stale snapshot info in database")
                            repair_snapshots_in_db
                                project_id : opts.project_id
                                host       : opts.dest.host
                                cb         : (ignore) ->
                                    cb(err)
                            return
                        else if output.stderr.indexOf('cannot receive incremental stream: most recent snapshot of') != -1
                            dbg("out of sync -- destroy the target; next time it should work.")
                            destroy_project
                                project_id : opts.project_id
                                host       : opts.dest.host
                                cb         : (ignore) ->
                                    cb("destroyed target project -- #{output.stderr}")
                            return
                        err = output.stderr
                    cb(err)
        (cb) ->
            dbg("update database to reflect the new list of snapshots resulting from this recv")
            # We use repair_snapshots to guarantee that this is correct.
            repair_snapshots_in_db
                project_id : opts.project_id
                host       : opts.dest.host
                cb         : cb
    ], (err) ->
        if clean_up
            dbg("remove the lock file")
            execute_on
                host    : opts.source.host
                command : "rm #{tmp}"
                timeout : 120
                cb      : (ignored) ->
                    opts.cb?(err)
        else
            dbg("no need to clean up -- bailing due to another process lock")
            opts.cb?(err)
    )

exports.destroy_project = destroy_project = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : required
        cb         : undefined

    dbg = (m) -> winston.debug("destroy_project(#{opts.project_id}, #{opts.host}: #{m}")

    async.series([
        (cb) ->
            dbg("kill any user processes")
            create_user
                project_id : opts.project_id
                host       : opts.host
                action     : 'kill'
                timeout    : 30
                cb         : cb
        (cb) ->
            dbg("delete dataset")
            execute_on
                host    : opts.host
                command : "sudo zfs destroy -r #{filesystem(opts.project_id)}"
                cb      : (err, output) ->
                    if err
                        if output?.stderr? and output.stderr.indexOf('does not exist') != -1
                            err = undefined
                    cb(err)
        (cb) ->
            dbg("throw in a umount, just in case")
            create_user
                project_id : opts.project_id
                host       : opts.host
                action     : 'umount'
                timeout    : 5
                cb         : (ignored) -> cb()
        (cb) ->
            dbg("success -- so record in database that project is no longer on this host.")
            set_snapshots_in_db
                project_id : opts.project_id
                host       : opts.host
                snapshots  : []
                cb         : cb
    ], (err) -> opts.cb?(err))

# Query database for *all* project's, sort them in alphabetical order,
# then run replicate on every single one.
# At the end, all projects should be replicated out to all their locations.
# Since the actual work happens all over the cluster (none on the machine
# running this, if it is a web machine), it is reasonable safe to run
# with a higher limit... maybe.
exports.replicate_all = replicate_all = (opts) ->
    opts = defaults opts,
        limit : 3   # no more than this many projects will be replicated simultaneously
        start : undefined  # if given, only takes projects.slice(start, stop) -- useful for debugging
        stop  : undefined
        cb    : undefined  # cb(err, {project_id:error when replicating that project})

    projects = undefined
    errors = {}
    done = 0
    todo = undefined
    async.series([
        (cb) ->
            database.select
                table   : 'projects'
                columns : ['project_id']
                limit   : if opts.stop? then opts.stop else 1000000       # TODO: change to use paging...
                cb      : (err, result) ->
                    if result?
                        projects = (x[0] for x in result)
                        projects.sort()
                        if opts.start? and opts.stop?
                            projects = projects.slice(opts.start, opts.stop)
                        todo = projects.length
                    cb(err)
        (cb) ->
            f = (project_id, cb) ->
                winston.debug("replicate_all -- #{project_id}")
                replicate
                    project_id : project_id
                    cb         : (err) ->
                        done += 1
                        winston.info("REPLICATE_ALL STATUS: finished #{done}/#{todo}")
                        if err
                            errors[project_id] = err
                        cb()
            async.mapLimit(projects, opts.limit, f, cb)
    ], (err) -> opts.cb?(err, errors))


###
# Migrate -- throw away code for migrating from the old /mnt/home/blah projects to new ones
###

#
# TEMPORARY: for migrate to work, you must:
#    - temporarily allow ssh key access to root@[all compute nodes]
#    - temporarily allow root to ssh to any project
#
exports.migrate = (opts) ->
    opts = defaults opts,
        project_id : required
        force      : false
        cb         : required
    dbg = (m) -> winston.debug("migrate(#{opts.project_id}): #{m}")
    dbg("migrate (or update) the data for project with given id to the new format")

    done = false
    old_home = undefined
    old_user = undefined
    old_host = undefined
    new_host = undefined
    now      = undefined
    rsync_failed = false
    async.series([
        (cb) ->
            if opts.force
                cb(); return
            dbg("check if project already completely migrated to new zfs storage format")
            database.select_one
                table   : 'projects'
                columns : ['storage']
                where   : {project_id : opts.project_id}
                cb      : (err, result) ->
                    if err
                        cb(err)
                    else
                        if result[0] == 'zfs'
                            dbg("nothing further to do -- project is now up and running using the new ZFS-based storage")
                            done = true
                            cb(true)
                        else
                            cb()
        (cb) ->
            if opts.force
                cb(); return
            dbg("get last modification time and last migration time of this project")
            database.select_one
                table   : 'projects'
                columns : ['last_edited', 'last_migrated', 'last_snapshot']
                where   : {project_id : opts.project_id}
                cb      : (err, result) ->
                    if err
                        cb(err)
                    else
                        last_edited = result[0]
                        last_migrated = result[1]
                        last_snapshot = result[2]
                        if (last_migrated and last_edited and (last_edited < last_migrated or last_edited<=last_snapshot)) or (last_migrated and not last_edited)
                            dbg("nothing to do  -- project hasn't changed since last successful rsync/migration or snapshot")
                            done = true
                            cb(true)
                        else
                            cb()

        (cb) ->
            dbg("determine /mnt/home path of the project")
            database.select_one
                table   : 'projects'
                columns : ['location', 'owner']
                json    : ['location']
                where   : {project_id : opts.project_id}
                cb      : (err, result) ->
                    dbg("location=#{misc.to_json(result[0])}")
                    if err
                        cb(err)
                    else
                        if not result[0] or not result[0].username or not result[0].host
                            if not result[1]
                                dbg("no owner either -- just an orphaned project entry")
                            done = true
                            database.update
                                table : 'projects'
                                set   : {'last_migrated':cassandra.now()}
                                where : {project_id : opts.project_id}
                            cb("no /mnt/home/ location for project -- migration not necessary")

                        else
                            old_user = result[0].username
                            old_home = '/mnt/home/' + result[0].username
                            old_host = result[0].host
                            cb()
        (cb) ->
            dbg("create a zfs version of the project (or find out where it is already)")
            create_project
                project_id : opts.project_id
                quota      : '10G'      # may shrink everything later...
                chown      : true       # in case of old messed up thing.
                exclude    : [old_host]
                unset_loc  : false
                cb         : (err, host) ->
                    new_host = host
                    dbg("initial zfs project host=#{new_host}")
                    cb(err)
        (cb) ->
            dbg("open the project on #{new_host}, so we can rsync old_home to it")
            open_project
                project_id : opts.project_id
                host       : new_host
                chown      : true
                cb         : cb
        (cb) ->
            dbg("rsync old_home to it.")
            new_home = mountpoint(opts.project_id)
            t = misc.walltime()
            now = cassandra.now()
            rsync = "rsync -Hax -e 'ssh -o StrictHostKeyChecking=no' --delete --exclude .forever --exclude .bup --exclude .zfs root@#{old_host}:#{old_home}/ #{new_home}/"
            execute_on
                user          : "root"
                host          : new_host
                command       : rsync
                err_on_stderr : false
                err_on_exit   : false
                cb            : (err, output) ->
                    # we set rsync_failed here, since it is critical that we do the chown below no matter what.
                    if err
                        rsync_failed = err
                    dbg("finished rsync; it took #{misc.walltime(t)} seconds; output=#{misc.to_json(output)}")
                    if output.exit_code and output.stderr.indexOf('readlink_stat("/mnt/home/teaAuZ9M/mnt")') == -1
                        rsync_failed = output.stderr
                        # TODO: ignore errors involving sshfs; be worried about other errors.
                    cb()
        (cb) ->
            dbg("chown user files")
            create_user
                project_id : opts.project_id
                host       : new_host
                action     : 'chown'
                cb         : (err) ->
                    if rsync_failed
                        err = rsync_failed
                    cb(err)

        (cb) ->
            dbg("take a snapshot")
            snapshot
                project_id              : opts.project_id
                host                    : new_host
                min_snapshot_interval_s : 0
                wait_for_replicate      : true
                force                   : true
                cb                      : cb
        (cb) ->
            dbg("close project")
            close_project
                project_id : opts.project_id
                host       : new_host
                unset_loc  : false
                cb         : cb

        (cb) ->
            dbg("record that we successfully migrated all data at this point in time (=when rsync *started*)")
            database.update
                table : 'projects'
                set   : {'last_migrated':now}
                where : {project_id : opts.project_id}
                cb    : cb
    ], (err) ->
        if done
            opts.cb()
        else
            opts.cb(err)
            if err
                log_error
                    project_id : opts.project_id
                    mesg       : {type:"migrate", "error":err}
    )


exports.migrate_all = (opts) ->
    opts = defaults opts,
        limit : 10  # no more than this many projects will be migrated simultaneously
        start : undefined  # if given, only takes projects.slice(start, stop) -- useful for debugging
        stop  : undefined
        exclude : undefined       # if given, any project_id in this array is skipped
        cb    : undefined  # cb(err, {project_id:error when replicating that project})

    projects = undefined
    errors = {}
    done = 0
    fail = 0
    todo = undefined
    dbg = (m) -> winston.debug("migrate_all(start=#{opts.start}, stop=#{opts.stop}): #{m}")
    t = misc.walltime()

    async.series([
        (cb) ->
            dbg("querying database...")
            database.select
                table   : 'projects'
                columns : ['project_id']
                limit   : 1000000                 # should page, but no need since this is throw-away code.
                cb      : (err, result) ->
                    if result?
                        dbg("got #{result.length} results in #{misc.walltime(t)} seconds")
                        projects = (x[0] for x in result)
                        projects.sort()
                        if opts.start? and opts.stop?
                            projects = projects.slice(opts.start, opts.stop)
                        if opts.exclude?
                            v = {}
                            for p in opts.exclude
                                v[p] = true
                            projects = (p for p in projects when not v[p])
                        todo = projects.length
                    cb(err)
        (cb) ->
            f = (project_id, cb) ->
                dbg("migrating #{project_id}")
                exports.migrate
                    project_id : project_id
                    cb         : (err) ->
                        if err
                            fail += 1
                        else
                            done += 1
                        winston.info("MIGRATE_ALL STATUS: (done=#{done} + fail=#{fail} = #{done+fail})/#{todo}")
                        if err
                            errors[project_id] = err
                        cb()
            async.mapLimit(projects, opts.limit, f, cb)
    ], (err) -> opts.cb?(err, errors))


#r=require('storage');r.init()
#x={};r.status_of_migrate_all(cb:(e,v)->console.log("DONE!"); x.v=v; console.log(x.v.done.length, x.v.todo.length))
exports.status_of_migrate_all = (opts) ->
    opts = defaults opts,
        cb    : undefined

    tm = misc.walltime()
    dbg = (m) -> winston.debug("status_of_migrate_all(): #{m}")
    dbg("querying db...")
    database.select
        table   : 'projects'
        columns : ['project_id','last_edited', 'last_migrated', 'last_snapshot', 'errors_zfs']
        limit   : 1000000
        cb      : (err, v) ->
            #dbg("v=#{misc.to_json(v)}")
            dbg("done querying in #{misc.walltime(tm)} seconds")
            if err
                opts.cb(err)
            else
                todo = []
                done = []

                for result in v
                    last_edited = result[1]
                    last_migrated = result[2]
                    last_snapshot = result[3]
                    if (last_migrated and last_edited and (last_edited < last_migrated or last_edited<=last_snapshot)) or (last_migrated and not last_edited)
                        done.push(result[0])
                    else
                        todo.push([result[0],result[4]])
                opts.cb(undefined, {done:done, todo:todo})

exports.location_all = (opts) ->
    opts = defaults opts,
        start : undefined  # if given, only takes projects.slice(start, stop) -- useful for debugging
        stop  : undefined
        cb    : undefined  # cb(err, {project_id:error when replicating that project})

    projects = undefined
    ans = []

    database.select
        table   : 'projects'
        columns : ['project_id','location']
        limit   : 1000000       # should page, but no need since this is throw-away code.
        cb      : (err, projects) ->
            if err
                opts.cb(err)
            else
                if projects?
                    projects.sort()
                    if opts.start? and opts.stop?
                        projects = projects.slice(opts.start, opts.stop)
                opts.cb(undefined, projects)


exports.repair_all = (opts) ->
    opts = defaults opts,
        start : undefined  # if given, only takes projects.slice(start, stop) -- useful for debugging
        stop  : undefined
        cb    : undefined  # cb(err, {project_id:actions, ...})

    dbg = (m) -> winston.debug("repair_all: #{m}")

    projects    = undefined
    wrong_locs  = {}
    wrong_snaps = {}
    async.series([
        (cb) ->
            dbg("querying db...")
            database.select
                table   : 'projects'
                columns : ['project_id','location','locations']
                limit   : 1000000       # should page, but no need since this is throw-away code.
                cb      : (err, projects) ->
                    if err
                        cb(err)
                    else
                        if projects?
                            projects.sort()
                            if opts.start? and opts.stop?
                                projects = projects.slice(opts.start, opts.stop)
                        cb()
        (cb) ->
            dbg("determining inconsistent replicas")
            for x in projects
                destroy = []
                loc = _.flatten(locations(project_id:x[0]))
                if loc.indexOf(x[1]) == -1 and x[2].indexOf(x[1]) != -1
                    if not wrong_locs[x[0]]?
                        wrong_locs[x[0]] = [x[1]]
                    else
                        wrong_locs[x[0]].push(x[1])

                v = ([s[0],h] for h,s of x[2] when s.length>0)
                if v.length > 0
                    v.sort()
                    best = v[v.length-1]
                    for h,s of x[2]
                        if s.length == 0 or s[0] != best
                            if not wrong_snaps[x[0]]?
                                wrong_snaps[x[0]] = [h]
                            else
                                wrong_snaps[x[0]].push(h)
            cb()
    ], (err) -> opts.cb?(err, {wrong_locs:wrong_locs, wrong_snaps:wrong_snaps}))




###
# init
###

exports.init = init = (cb) ->
    connect_to_database(cb)

# TODO
#init (err) ->
#    winston.debug("init -- #{err}")






