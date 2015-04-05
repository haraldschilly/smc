###############################################################################
#
# SageMathCloud: A collaborative web-based interface to Sage, Python, LaTeX and the Terminal.
#
#    Copyright (C) 2014, 2015, William Stein
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################

###

Jupyter Notebook Synchronization






###


async                = require('async')

misc                 = require('misc')
{defaults, required} = misc

{salvus_client}      = require('salvus_client')

diffsync             = require('diffsync')
syncdoc              = require('syncdoc')

templates            = $(".smc-jupyter-templates")

editor_templates     = $("#salvus-editor-templates")

exports.jupyter_nbviewer = (editor, filename, content, opts) ->
    X = new JupyterNBViewer(editor, filename, content, opts)
    element = X.element
    element.data('jupyter_nbviewer', X)
    return element

class JupyterNBViewer
    constructor: (@editor, @filename, @content, opts) ->
        @element = templates.find(".smc-jupyter-nbviewer").clone()
        @ipynb_filename = @filename.slice(0,@filename.length-4) + 'ipynb'
        @init_buttons()

    show: () =>
        if not @iframe?
            @iframe = @element.find(".smc-jupyter-nbviewer-content").find('iframe')
            # We do this, since otherwise just loading the iframe using
            #      @iframe.contents().find('html').html(@content)
            # messes up the parent html page, e.g., foo.modal() is gone.
            @iframe.contents().find('body')[0].innerHTML = @content

        @element.css(top:@editor.editor_top_position())
        @element.maxheight(offset:18)
        @element.find(".smc-jupyter-nbviewer-content").maxheight(offset:18)
        @iframe.maxheight(offset:18)

    init_buttons: () =>
        @element.find("a[href=#copy]").click () =>

            @editor.project_page.copy_to_another_project_dialog @ipynb_filename, false, (err, x) =>
                console.log("x=#{misc.to_json(x)}")
                if not err
                    require('projects').open_project
                        project   : x.project_id
                        target    : "files/" + x.path
                        switch_to : true
            return false

        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false

        @element.find("a[href=#download]").click () =>
            @editor.project_page.download_file
                path : @ipynb_filename
            return false


ipython_notebook_server = (opts) ->
    console.log("ipython_notebook_server")
    opts = defaults opts,
        project_id : required
        path       : '.'   # directory from which the files are served -- default to home directory of project
        cb         : required   # cb(err, server)

    I = new IPythonNotebookServer(opts.project_id, opts.path)
    console.log("ipython_notebook_server: got object")
    I.start_server (err, base) =>
        opts.cb(err, I)

class IPythonNotebookServer  # call ipython_notebook_server above
    constructor: (@project_id, @path) ->

    start_server: (cb) =>
        console.log("start_server")
        salvus_client.exec
            project_id : @project_id
            path       : @path
            command    : "ipython-notebook"
            args       : ['start']
            bash       : false
            timeout    : 40
            err_on_exit: false
            cb         : (err, output) =>
                console.log("start_server got back ", err, output)
                if err
                    cb?(err)
                else
                    try
                        info = misc.from_json(output.stdout)
                        if info.error?
                            cb?(info.error)
                        else
                            @url = info.base; @pid = info.pid; @port = info.port
                            if not @url? or not @pid? or not @port?
                                # probably starting up -- try again in 3 seconds
                                setTimeout((()=>@start_server(cb)), 3000)
                                return
                            get_with_retry
                                url : @url
                                cb  : (err, data) =>
                                    cb?(err)
                    catch e
                        cb?("error parsing ipython server output -- #{output.stdout}, #{e}")

    stop_server: (cb) =>
        if not @pid?
            cb?(); return
        salvus_client.exec
            project_id : @project_id
            path       : @path
            command    : "ipython-notebook"
            args       : ['stop']
            bash       : false
            timeout    : 15
            cb         : (err, output) =>
                cb?(err)

# Download a remote URL, possibly retrying repeatedly with exponential backoff
# on the timeout.
# If the downlaod URL contains bad_string (default: 'ECONNREFUSED'), also retry.
get_with_retry = (opts) ->
    opts = defaults opts,
        url           : required
        initial_timeout : 5000
        max_timeout     : 15000     # once delay hits this, give up
        factor        : 1.1     # for exponential backoff
        bad_string    : 'ECONNREFUSED'
        cb            : required  # cb(err, data)  # data = content of that url
    timeout = opts.initial_timeout
    delay   = 50
    f = () =>
        if timeout >= opts.max_timeout  # too many attempts
            opts.cb("unable to connect to remote server")
            return
        $.ajax(
            url     : opts.url
            timeout : timeout
            success : (data) ->
                if data.indexOf(opts.bad_string) != -1
                    timeout *= opts.factor
                    setTimeout(f, delay)
                else
                    opts.cb(false, data)
        ).fail(() ->
            timeout *= opts.factor
            delay   *= opts.factor
            setTimeout(f, delay)
        )

    f()


# Embedded editor for editing IPython notebooks.  Enhanced with sync and integrated into the
# overall cloud look.

# Extension for the file used for synchronization of IPython
# notebooks between users.
# In the rare case that we change the format, must increase this and
# also increase the version number forcing users to refresh their browser.
IPYTHON_SYNCFILE_EXTENSION = ".syncdoc4"

exports.jupyter_notebook = (editor, filename, opts) ->
    J = new JupyterNotebook(editor, filename, opts)
    return J.element

class JupyterNotebook
    dbg: (f, m...) =>
        console.log("#{new Date()} -- JupyterNotebook.#{f}: #{misc.to_json(m)}")

    constructor: (@editor, @filename, opts={}) ->
        opts = @opts = defaults opts,
            sync_interval : 500
            cursor_interval : 2000
        window.ipython = @
        @element = templates.find(".smc-jupyter-notebook").clone()
        @element.data("jupyter_notebook", @)

        # Jupyter is now proxied via a canonical URL
        @server_url = "/#{@editor.project_id}/port/jupyter/"

        @_start_time = misc.walltime()
        if window.salvus_base_url != ""
            # TODO: having a base_url doesn't imply necessarily that we're in a dangerous devel mode...
            # (this is just a warning).
            # The solutiion for this issue will be to set a password whenever ipython listens on localhost.
            @element.find(".smc-jupyter-notebook-danger").show()
            setTimeout( ( () => @element.find(".smc-jupyter-notebook-danger").hide() ), 3000)

        @status_element = @element.find(".smc-jupyter-notebook-status-messages")
        @init_buttons()
        s = misc.path_split(@filename)
        @path = s.head
        @file = s.tail

        if @path
            @syncdoc_filename = @path + '/.' + @file + IPYTHON_SYNCFILE_EXTENSION
        else
            @syncdoc_filename = '.' + @file + IPYTHON_SYNCFILE_EXTENSION

        # This is where we put the page itself
        @notebook = @element.find(".smc-jupyter-notebook-notebook")
        @con = @element.find(".smc-jupyter-notebook-connecting")
        @setup () =>
            # TODO: We have to do this stupid thing because in IPython's notebook.js they don't systematically use
            # set_dirty, sometimes instead just directly seting the flag.  So there's no simple way to know exactly
            # when the notebook is dirty. (TODO: fix all this via upstream patches.)
            # Also, note there are cases where IPython doesn't set the dirty flag
            # even though the output has changed.   For example, if you type "123" in a cell, run, then
            # comment out the line and shift-enter again, the empty output doesn't get sync'd out until you do
            # something else.  If any output appears then the dirty happens.  I guess this is a bug that should be fixed in ipython.
            @_autosync_interval = setInterval(@autosync, @opts.sync_interval)
            @_cursor_interval = setInterval(@broadcast_cursor_pos, @opts.cursor_interval)

    status: (text) =>
        if not text?
            text = ""
        else if false
            text += " (started at #{Math.round(misc.walltime(@_start_time))}s)"
        @status_element.html(text)

    setup: (cb) =>
        if @_setting_up
            cb?("already setting up")
            return  # already setting up
        @_setting_up = true
        @con.show().icon_spin(start:true)
        delete @_cursors   # Delete all the cached cursors in the DOM
        delete @nb
        delete @frame

        async.series([
            (cb) =>
                @status("Checking whether ipynb file has changed...")
                salvus_client.exec
                    project_id : @editor.project_id
                    path       : @path
                    command    : "stat"   # %Z below = time of last change, seconds since Epoch; use this not %Y since often users put file in place, but with old time
                    args       : ['--printf', '%Z ', @file, @syncdoc_filename]
                    timeout    : 15
                    err_on_exit: false
                    cb         : (err, output) =>
                        if err
                            cb(err)
                        else if output.stderr.indexOf('such file or directory') != -1
                            # nothing to do -- the syncdoc file doesn't even exist.
                            cb()
                        else
                            v = output.stdout.split(' ')
                            if parseInt(v[0]) >= parseInt(v[1]) + 10
                                @_use_disk_file = true
                            cb()
            (cb) =>
                @status("Ensuring synchronization file exists")
                @editor.project_page.ensure_file_exists
                    path  : @syncdoc_filename
                    alert : false
                    cb    : (err) =>
                        if err
                            # unable to create syncdoc file -- open in non-sync read-only mode.
                            @readonly = true
                        else
                            @readonly = false
                        #console.log("ipython: readonly=#{@readonly}")
                        cb()
            (cb) =>
                @initialize(cb)
            (cb) =>
                if @readonly
                    # TODO -- change UI to say *READONLY*
                    @iframe.css(opacity:1)
                    @save_button.text('Readonly').addClass('disabled')
                    @show()
                    cb()
                else
                    @_init_doc(cb)
        ], (err) =>
            @con.show().icon_spin(false).hide()
            @_setting_up = false
            if err
                @save_button.addClass("disabled")
                @status("Failed to start -- #{err}")
                cb?("Unable to start Jupyter notebook server -- #{err}")
            else
                cb?()
        )

    _init_doc: (cb) =>
        #console.log("_init_doc: connecting to sync session")
        @status("Connecting to synchronized editing session...")
        if @doc?
            # already initialized
            @doc.sync () =>
                @set_live_from_syncdoc()
                @iframe.css(opacity:1)
                @show()
                cb?()
            return
        @doc = syncdoc.synchronized_string
            project_id : @editor.project_id
            filename   : @syncdoc_filename
            sync_interval : @opts.sync_interval
            cb         : (err) =>
                #console.log("_init_doc returned: err=#{err}")
                @status()
                if err
                    cb?("Unable to connect to synchronized document server -- #{err}")
                else
                    if @_use_disk_file
                        @doc.live('')
                    @_config_doc()
                    cb?()

    _config_doc: () =>
        #console.log("_config_doc")
        # todo -- should check if .ipynb file is newer... ?
        @status("Displaying Jupyter Notebook")
        if @doc.live() == ''
            @doc.live(@to_doc())
        else
            @set_live_from_syncdoc()
        #console.log("DONE SETTING!")
        @iframe.css(opacity:1)
        @show()

        @doc._presync = () =>
            if not @nb? or @_reloading
                # no point -- reinitializing the notebook frame right now...
                return
            @doc.live(@to_doc())

        apply_edits = @doc.dsync_client._apply_edits_to_live

        apply_edits2 = (patch, cb) =>
            #console.log("_apply_edits_to_live ")#-- #{JSON.stringify(patch)}")
            before =  @to_doc()
            if not before?
                cb?("reloading")
                return
            @doc.dsync_client.live = before
            apply_edits(patch)
            if @doc.dsync_client.live != before
                @from_doc(@doc.dsync_client.live)
                #console.log("edits should now be applied!")#, @doc.dsync_client.live)
            cb?()

        @doc.dsync_client._apply_edits_to_live = apply_edits2

        @doc.on "reconnect", () =>
            @dbg("_config_doc", "reconnect")
            if not @doc.dsync_client?
                # this could be an older connect emit that didn't get handled -- ignore.
                return
            apply_edits = @doc.dsync_client._apply_edits_to_live
            @doc.dsync_client._apply_edits_to_live = apply_edits2
            # Update the live document with the edits that we missed when offline
            @status("Reconnecting and updating live document...")
            @from_doc(@doc.dsync_client.live)
            @status()

        # TODO: we should just create a class that derives from SynchronizedString at this point.
        @doc.draw_other_cursor = (pos, color, name) =>
            if not @_cursors?
                @_cursors = {}
            id = color + name
            cursor_data = @_cursors[id]
            if not cursor_data?
                if not @frame?.$?
                    # do nothing in case initialization is incomplete
                    return
                cursor = editor_templates.find(".salvus-editor-codemirror-cursor").clone().show()
                # craziness -- now move it into the iframe!
                cursor = @frame.$("<div>").html(cursor.html())
                cursor.css(position: 'absolute', width:'15em')
                inside = cursor.find(".salvus-editor-codemirror-cursor-inside")
                inside.css
                    'background-color': color
                    position : 'absolute'
                    top : '-1.3em'
                    left: '.5ex'
                    height : '1.15em'
                    width  : '.1ex'
                    'border-left': '2px solid black'
                    border  : '1px solid #aaa'
                    opacity :'.7'

                label = cursor.find(".salvus-editor-codemirror-cursor-label")
                label.css
                    color:'color'
                    position:'absolute'
                    top:'-2.3em'
                    left:'1.5ex'
                    'font-size':'8pt'
                    'font-family':'serif'
                    'z-index':10000
                label.text(name)
                cursor_data = {cursor: cursor, pos:pos}
                @_cursors[id] = cursor_data
            else
                cursor_data.pos = pos

            # first fade the label out
            c = cursor_data.cursor.find(".salvus-editor-codemirror-cursor-label")
            if c.length > 0
                c.stop().show().animate(opacity:1).fadeOut(duration:16000)
                # Then fade the cursor out (a non-active cursor is a waste of space).
                cursor_data.cursor.stop().show().animate(opacity:1).fadeOut(duration:60000)
                @nb?.get_cell(pos.index)?.code_mirror.addWidget(
                          {line:pos.line,ch:pos.ch}, cursor_data.cursor[0], false)
        @status()


    broadcast_cursor_pos: () =>
        if not @nb? or @readonly
            # no point -- reloading or loading or read-only
            return
        index = @nb.get_selected_index()
        cell  = @nb.get_cell(index)
        if not cell?
            return
        pos   = cell.code_mirror.getCursor()
        s = misc.to_json(pos)
        if s != @_last_cursor_pos
            @_last_cursor_pos = s
            @doc.broadcast_cursor_pos(index:index, line:pos.line, ch:pos.ch)

    remove: () =>
        if @_sync_check_interval?
            clearInterval(@_sync_check_interval)
        if @_cursor_interval?
            clearInterval(@_cursor_interval)
        if @_autosync_interval?
            clearInterval(@_autosync_interval)
        if @_reconnect_interval?
            clearInterval(@_reconnect_interval)
        @element.remove()
        @doc?.disconnect_from_session()
        @_dead = true

    # Initialize the embedded iframe and wait until the notebook object in it is initialized.
    # If this returns (calls cb) without an error, then the @nb attribute must be defined.
    initialize: (cb) =>
        @dbg("initialize")
        @status("Rendering Jupyter notebook")
        get_with_retry
            url : @server_url
            cb  : (err) =>
                if err
                    @dbg("_init_iframe", "error", err)
                    @status()
                    #console.log("exit _init_iframe 2")
                    cb(err); return

                @iframe_uuid = misc.uuid()

                @status("Loading Jupyter notebook...")
                @iframe = $("<iframe name=#{@iframe_uuid} id=#{@iframe_uuid} style='opacity:.05'>").attr('src', "#{@server_url}notebooks/#{@filename}")
                @notebook.html('').append(@iframe)
                @show()

                # Monkey patch the IPython html so clicking on the IPython logo pops up a new tab with the dashboard,
                # instead of messing up our embedded view.
                attempts = 0
                delay = 200
                start_time = misc.walltime()
                # What f does below is purely inside the browser DOM -- not the network, so doing it frequently is not a serious
                # problem for the server.
                f = () =>
                    #console.log("(attempt #{attempts}, time #{misc.walltime(start_time)}): @frame.ipython=#{@frame?.IPython?}, notebook = #{@frame?.IPython?.notebook?}, kernel= #{@frame?.IPython?.notebook?.kernel?}")
                    if @_dead?
                        cb("dead"); return
                    attempts += 1
                    if delay <= 750  # exponential backoff up to 300ms.
                        delay *= 1.2
                    if attempts >= 80
                        # give up after this much time.
                        msg = "Failed to load Jupyter notebook"
                        @status(msg)
                        #console.log("exit _init_iframe 3")
                        cb(msg)
                        return
                    @frame = window.frames[@iframe_uuid]
                    if not @frame? or not @frame?.$? or not @frame.IPython? or not @frame.IPython.notebook? or not @frame.IPython.notebook.kernel?
                        setTimeout(f, delay)
                    else
                        a = @frame.$("#ipython_notebook").find("a")
                        if a.length == 0
                            setTimeout(f, delay)
                        else
                            @ipython = @frame.IPython
                            if not @ipython.notebook?
                                msg = "BUG -- Something went wrong -- notebook object not defined in Jupyter frame"
                                @status(msg)
                                #console.log("exit _init_iframe 4")
                                cb(msg)
                                return
                            @nb = @ipython.notebook

                            a.click () =>
                                @info()
                                return false

                            # Replace the IPython Notebook logo, which is for some weird reason an ugly png, with proper HTML; this ensures the size
                            # and color match everything else.
                            #a.html('<span style="font-size: 18pt;"><span style="color:black">IP</span>[<span style="color:black">y</span>]: Notebook</span>')

                            # proper file rename with sync not supported yet (but will be -- TODO; needs to work with sync system)
                            @frame.$("#notebook_name").unbind('click').css("line-height",'0em')

                            # Get rid of file menu, which weirdly and wrongly for sync replicates everything.
                            for cmd in ['new', 'open', 'copy', 'rename']
                                @frame.$("#" + cmd + "_notebook").remove()
                            @frame.$("#kill_and_exit").remove()
                            @frame.$("#menus").find("li:first").find(".divider").remove()

                            #@frame.$('<style type=text/css></style>').html(".container{width:98%; margin-left: 0;}").appendTo(@frame.$("body"))

                            @frame.$('<style type=text/css></style>').appendTo(@frame.$("body"))

                            @nb._save_checkpoint = @nb.save_checkpoint
                            @nb.save_checkpoint = @save

                            if @readonly
                                @frame.$("#save_widget").append($("<b style='background: red;color: white;padding-left: 1ex; padding-right: 1ex;'>This is a READONLY document that can't be saved.</b>"))

                            # Jupyter doesn't consider a load (e.g., snapshot restore) "dirty" (for obvious reasons!)
                            @nb._load_notebook_success = @nb.load_notebook_success
                            @nb.load_notebook_success = (data,status,xhr) =>
                                @nb._load_notebook_success(data,status,xhr)
                                @sync()

                            # This would Periodically reconnect the IPython websocket.  This is LAME to have to do, but if I don't do this,
                            # then the thing hangs and reconnecting then doesn't work (the user has to do a full frame refresh).
                            # TODO: understand this and fix it properly.  This is entirely related to the complicated proxy server
                            # stuff in SMC, not sync!
                            ##websocket_reconnect = () =>
                            ##    @nb?.kernel?.start_channels()
                            ##@_reconnect_interval = setInterval(websocket_reconnect, 60000)

                            @status()
                            cb()

                setTimeout(f, delay)

    autosync: () =>
        if @readonly
            return
        if @frame?.IPython?.notebook?.dirty and not @_reloading
            @dbg("autosync")
            #console.log("causing sync")
            @save_button.removeClass('disabled')
            @sync()
            @nb.dirty = false

    sync: () =>
        if @readonly
            return
        @editor.activity_indicator(@filename)
        @save_button.icon_spin(start:true, delay:1000)
        @doc.sync () =>
            @save_button.icon_spin(false)

    has_unsaved_changes: () =>
        return not @save_button.hasClass('disabled')

    save: (cb) =>
        if not @nb? or @readonly
            cb?(); return
        @save_button.icon_spin(start:true, delay:1000)
        @nb.save_notebook?(false)
        @doc.save () =>
            @save_button.icon_spin(false)
            @save_button.addClass('disabled')
            cb?()

    set_live_from_syncdoc: () =>
        if not @doc?.dsync_client?  # could be re-initializing
            return
        current = @to_doc()
        if not current?
            return
        if @doc.dsync_client.live != current
            @from_doc(@doc.dsync_client.live)

    info: () =>
        t = "<h3>The Jupyter Notebook</h3>"
        t += "<h4>Enhanced with SageMathCloud Sync</h4>"
        t += "You are editing this document using the Jupyter Notebook enhanced with realtime synchronization."
        t += "<h4>Use Sage by pasting this into a cell</h4>"
        t += "<pre>%load_ext sage</pre>"
        #t += "<h4>Connect to this Jupyter kernel in a terminal</h4>"
        #t += "<pre>ipython console --existing #{@kernel_id}</pre>"
        t += "<h4>Pure Jupyter notebooks</h4>"
        t += "You can <a target='_blank' href='#{@server_url}notebooks/#{@filename}'>open this notebook in a vanilla Jupyter Notebook server without sync</a> (this link works only for project collaborators).  "
        #t += "<br><br>To start your own unmodified Jupyter Notebook server that is securely accessible to collaborators, type in a terminal <br><br><pre>ipython-notebook run</pre>"
        t += "<h4>Known Issues</h4>"
        t += "If two people edit the same <i>cell</i> simultaneously, the cursor will jump to the start of the cell."
        bootbox.alert(t)
        return false

    reload: () =>
        if @_reloading
            return
        @_reloading = true
        @_cursors = {}
        @reload_button.find("i").addClass('fa-spin')
        @initialize (err) =>
            @_init_doc () =>
                @_reloading = false
                @status('')
                @reload_button.find("i").removeClass('fa-spin')

    init_buttons: () =>
        @element.find("a").tooltip(delay:{show: 500, hide: 100})
        @save_button = @element.find("a[href=#save]").click () =>
            @save()
            return false

        @reload_button = @element.find("a[href=#reload]").click () =>
            @reload()
            return false

        @publish_button = @element.find("a[href=#publish]").click () =>
            @publish_ui()
            return false

        #@element.find("a[href=#json]").click () =>
        #    console.log(@to_obj())

        @element.find("a[href=#info]").click () =>
            @info()
            return false

        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false

        @element.find("a[href=#execute]").click () =>
            @nb?.execute_selected_cell()
            return false
        @element.find("a[href=#interrupt]").click () =>
            @nb?.kernel.interrupt()
            return false
        @element.find("a[href=#tab]").click () =>
            @nb?.get_cell(@nb?.get_selected_index()).completer.startCompletion()
            return false

    publish_ui: () =>
        url = document.URL
        url = url.slice(0,url.length-5) + 'html'
        dialog = templates.find(".smc-jupyter-publish-dialog").clone()
        dialog.modal('show')
        dialog.find(".btn-close").off('click').click () ->
            dialog.modal('hide')
            return false
        status = (mesg, percent) =>
            dialog.find(".smc-jupyter-publish-status").text(mesg)
            p = "#{percent}%"
            dialog.find(".progress-bar").css('width',p).text(p)

        @publish status, (err) =>
            dialog.find(".smc-jupyter-publish-dialog-publishing")
            if err
                dialog.find(".smc-jupyter-publish-dialog-fail").show().find('span').text(err)
            else
                dialog.find(".smc-jupyter-publish-dialog-success").show()
                url_box = dialog.find(".smc-jupyter-publish-url")
                url_box.val(url)
                url_box.click () ->
                    $(this).select()

    publish: (status, cb) =>
        #d = (m) => console.log("ipython.publish('#{@filename}'): #{misc.to_json(m)}")
        #d()
        @publish_button.find("fa-refresh").show()
        async.series([
            (cb) =>
                status?("saving",0)
                @save(cb)
            (cb) =>
                status?("running nbconvert",30)
                @nbconvert
                    format : 'html'
                    cb     : (err) =>
                        cb(err)
            (cb) =>
                status?("making '#{@filename}' public", 70)
                @editor.project_page.publish_path
                    path        : @filename
                    description : "Jupyter notebook #{@filename}"
                    cb          : cb
            (cb) =>
                html = @filename.slice(0,@filename.length-5)+'html'
                status?("making '#{html}' public", 90)
                @editor.project_page.publish_path
                    path        : html
                    description : "Jupyter html version of #{@filename}"
                    cb          : cb
        ], (err) =>
            status?("done", 100)
            @publish_button.find("fa-refresh").hide()
            cb?(err)
        )

    nbconvert: (opts) =>
        opts = defaults opts,
            format : required
            cb     : undefined
        salvus_client.exec
            path        : @path
            project_id  : @editor.project_id
            command     : 'ipython'
            args        : ['nbconvert', @file, "--to=#{opts.format}"]
            bash        : false
            err_on_exit : true
            timeout     : 30
            cb          : (err, output) =>
                console.log("nbconvert finished with err='#{err}, output='#{misc.to_json(output)}'")
                opts.cb?(err)

    # WARNING: Do not call this before @nb is defined!
    to_obj: () =>
        #console.log("to_obj: start"); t = misc.mswalltime()
        if not @nb?
            # can't get obj
            return undefined
        obj = @nb.toJSON()
        obj.metadata.name  = @nb.notebook_name
        obj.nbformat       = @nb.nbformat
        obj.nbformat_minor = @nb.nbformat_minor
        #console.log("to_obj: done", misc.mswalltime(t))
        return obj

    from_obj: (obj) =>
        #console.log("from_obj: start"); t = misc.mswalltime()
        if not @nb?
            return
        i = @nb.get_selected_index()
        st = @nb.element.scrollTop()
        @nb.fromJSON(obj)
        @nb.dirty = false
        @nb.select(i)
        @nb.element.scrollTop(st)
        #console.log("from_obj: done", misc.mswalltime(t))

    ###
    # simplistic version of modifying the notebook in place.  VERY slow when new cell added.
    from_doc0: (doc) =>
        #console.log("from_doc: start"); t = misc.mswalltime()
        nb = @nb
        v = doc.split('\n')
        nb.metadata.name  = v[0].notebook_name
        cells = []
        for line in v.slice(1)
            try
                c = misc.from_json(line)
                cells.push(c)
            catch e
                console.log("error de-jsoning '#{line}'", e)
        obj = @to_obj()
        obj.cells = cells
        @from_obj(obj)
        console.log("from_doc: done", misc.mswalltime(t))
    ###

    delete_cell: (index) =>
        @nb?.delete_cell(index)

    insert_cell: (index, cell_data) =>
        if not @nb?
            return
        new_cell = @nb.insert_cell_at_index(cell_data.cell_type, index)
        new_cell.fromJSON(cell_data)

    set_cell: (index, cell_data) =>
        #console.log("set_cell: start"); t = misc.mswalltime()
        @dbg("set_cell", index, cell_data)
        if not @nb?
            return

        cell = @nb.get_cell(index)

        if false and cell? and cell_data.cell_type == cell.cell_type
            #console.log("setting in place")

            if cell.output_area?
                # for some reason fromJSON doesn't clear the output (it should, imho), and the clear_output method
                # on the output_area doesn't work as expected.
                wrapper = cell.output_area.wrapper
                wrapper.empty()
                cell.output_area = new @ipython.OutputArea(wrapper, true)

            cell.fromJSON(cell_data)

            ###  for debugging that we properly update a cell in place -- if this is wrong,
            #    all hell breaks loose, and sync loops ensue.
            a = misc.to_json(cell_data)
            b = misc.to_json(cell.toJSON())
            if a != b
                console.log("didn't work:")
                console.log(a)
                console.log(b)
                @nb.delete_cell(index)
                new_cell = @nb.insert_cell_at_index(cell_data.cell_type, index)
                new_cell.fromJSON(cell_data)
            ###

        else
            #console.log("replacing")
            @nb.delete_cell(index)
            new_cell = @nb.insert_cell_at_index(cell_data.cell_type, index)
            new_cell.fromJSON(cell_data)
        #console.log("set_cell: done", misc.mswalltime(t))

    ###
    # simplistic version of setting from doc; *very* slow on cell insert.
    from_doc0: (doc) =>
        console.log("goal='#{doc}'")
        console.log("live='#{@to_doc()}'")

        console.log("from_doc: start"); t = misc.mswalltime()
        goal = doc.split('\n')
        live = @to_doc().split('\n')

        @nb.metadata.name  = goal[0].notebook_name

        for i in [1...Math.max(goal.length, live.length)]
            index = i-1
            if i >= goal.length
                console.log("deleting cell #{index}")
                @nb.delete_cell(index)
            else if goal[i] != live[i]
                console.log("replacing cell #{index}")
                try
                    cell_data = JSON.parse(goal[i])
                    @set_cell(index, cell_data)
                catch e
                    console.log("error de-jsoning '#{goal[i]}'", e)

        console.log("from_doc: done", misc.mswalltime(t))
    ###

    # Notebook Doc Format: line 0 is meta information in JSON.
    # Rest of file has one line for each cell for rest of file, in the following format:
    #
    #     cell input text (with newlines replaced) [special unicode character] json object for cell, without input
    #
    # We split the line as above so that if/when there are merge conflicts
    # that result in json corruption, which we then reject, only the *output*
    # is impacted. The odds of corruption in the output is much less.
    #
    cell_to_line: (cell) =>
        cell = misc.copy(cell)
        source = misc.to_json(cell.source)
        delete cell['source']
        line = source + diffsync.MARKERS.output + misc.to_json(cell)
        #console.log("\n\ncell=", misc.to_json(cell))
        #console.log("line=", line)
        return line

    line_to_cell: (line) =>
        v = line.split(diffsync.MARKERS.output)
        try
            if v[0] == 'undefined'  # backwards incompatibility...
                source = undefined
            else
                source = JSON.parse(v[0])
        catch e
            console.log("line_to_cell('#{line}') -- source ERROR=", e)
            return
        try
            cell = JSON.parse(v[1])
            cell.source = source
        catch e
            console.log("line_to_cell('#{line}') -- output ERROR=", e)
        #console.log("\n\nlin=", line)
        #console.log("cell=", misc.to_json(cell))
        return cell

    to_doc: () =>
        #console.log("to_doc: start"); t = misc.mswalltime()
        obj = @to_obj()
        if not obj?
            return
        doc = misc.to_json({notebook_name:obj.metadata.name})
        for cell in obj.cells
            doc += '\n' + @cell_to_line(cell)
        #console.log("to_doc: done", misc.mswalltime(t))
        return doc

    from_doc: (doc) =>
        #console.log("goal='#{doc}'")
        #console.log("live='#{@to_doc()}'")
        #console.log("from_doc: start"); tm = misc.mswalltime()
        if not @nb?
            # The live notebook is not currently initialized -- there's nothing to be done for now.
            # This can happen if reconnect (to hub) happens at the same time that user is reloading
            # the ipython notebook frame itself.   The doc will get set properly at the end of the
            # reload anyways, so no need to set it here.
            return

        # We want to transform live into goal.
        goal = doc.split('\n')
        live = @to_doc()?.split('\n')
        if not live?
            # reloading...
            return
        @nb.metadata.name  = goal[0].notebook_name

        v0    = live.slice(1)
        v1    = goal.slice(1)
        string_mapping = new misc.StringCharMapping()
        v0_string  = string_mapping.to_string(v0)
        v1_string  = string_mapping.to_string(v1)
        diff = diffsync.dmp.diff_main(v0_string, v1_string)

        index = 0
        i = 0

        #console.log("diff=#{misc.to_json(diff)}")
        i = 0
        while i < diff.length
            chunk = diff[i]
            op    = chunk[0]  # -1 = delete, 0 = leave unchanged, 1 = insert
            val   = chunk[1]
            if op == 0
                # skip over  cells
                index += val.length
            else if op == -1
                # Deleting cell
                # A common special case arises when one is editing a single cell, which gets represented
                # here as deleting then inserting.  Replacing is far more efficient than delete and add,
                # due to the overhead of creating codemirror instances (presumably).  (Also, there is a
                # chance to maintain the cursor later.)
                if i < diff.length - 1 and diff[i+1][0] == 1 and diff[i+1][1].length == val.length
                    #console.log("replace")
                    for x in diff[i+1][1]
                        obj = @line_to_cell(string_mapping._to_string[x])
                        if obj?
                            @set_cell(index, obj)
                        index += 1
                    i += 1 # skip over next chunk
                else
                    #console.log("delete")
                    for j in [0...val.length]
                        @delete_cell(index)
            else if op == 1
                # insert new cells
                #console.log("insert")
                for x in val
                    obj = @line_to_cell(string_mapping._to_string[x])
                    if obj?
                        @insert_cell(index, obj)
                    index += 1
            else
                console.log("BUG -- invalid diff!", diff)
            i += 1

        #console.log("from_doc: done", misc.mswalltime(tm))
        #if @to_doc() != doc
        #    console.log("FAIL!")
        #    console.log("goal='#{doc}'")
        #    console.log("live='#{@to_doc()}'")
        #    @from_doc0(doc)

    focus: () =>
        # TODO
        # console.log("ipython notebook focus: todo")

    show: () =>
        top = @editor.editor_top_position()
        @element.css(top:top)
        if top == 0
            @element.css('position':'fixed')
        w = $(window).width()
        # console.log("top=#{top}; setting maxheight for iframe =", @iframe)
        @iframe?.attr('width',w).maxheight()
        setTimeout((()=>@iframe?.maxheight()), 1)   # set it one time more the next render loop.
