#
# * gith
# * https://github.com/danheberden/gith
# *
# * Copyright (c) 2012 Dan Heberden
# * Licensed under the MIT license.
# 
http = require("http")
EventEmitter2 = require("eventemitter2").EventEmitter2
util = require("util")
_ = require("lodash")
querystring = require("querystring")

# rais
debug = require("debug")("gith:")

#
filterSettings = (settings, payload) ->
    return false  unless payload
    settings = settings or {}

    # add the matches object for later
    payload.matches = {}

    # check all the things
    checksPassed = true
    [
        "repo"
        "branch"
        "file"
        "tag"
    ].forEach (thing) ->
        wat = settings[thing]

        # default to a passed state
        passed = true

        # was a filter specified? and is it not a wildcard?
        if wat and wat isnt "*"

            # checking, so default passed to false
            passed = false

            # make an array of the thing or all the files
            checks = [].concat((if thing is "file" then payload.files.all else payload[thing]))

            # all the checks - did any of them pass?
            passed = checks.some((check) ->

                # direct match
                return true  if wat is check

                # if negated match (!string)
                return true  if _.isString(wat) and wat[0] is "!" and wat.slice(1) isnt check

                # regex?
                if _.isRegExp(wat)
                    match = check.match(wat)

                    # did it match? huh? did it?
                    if match

                        # goddamn files being different
                        if thing is "file"
                            payload.matches.files = {}  unless payload.matches.files
                            payload.matches.files[check] = match
                        else
                            payload.matches[thing] = match
                        true
            )

            # usr function?
            passed = wat(payload[thing], payload)  if _.isFunction(wat)

            # assign the final result of this 'thing' to checksPassed
            checksPassed = passed and checksPassed
        return

    checksPassed


# Used by exports.module.create's returned function to create
# new gith objects that hold settings and emit events
Gith = (eventaur, settings) ->
    gith = this
    @settings = settings or {}

    # make this bad boy an event emitter
    EventEmitter2.call this,
        delimiter: ":"
        maxListeners: 0


    # handle bound payloads
    eventaur.on "payload", (originalPayload) ->

        # make a simpler payload
        payload = gith.simplifyPayload(originalPayload)
        debug 'filterSettings:',filterSettings(settings, payload)
        # bother doing anything?
        if filterSettings(settings, payload)

            # all the things
            gith.emit "all", payload

            # did we do any branch work?
            gith.emit "branch:add", payload  if originalPayload.created and originalPayload.forced and payload.branch
            gith.emit "branch:delete", payload  if originalPayload.deleted and originalPayload.forced and payload.branch
            # commits
            gith.emit "branch:commits", payload if originalPayload.commits? and payload.branch
            # how about files?
            gith.emit "file:add", payload  if payload.files.added.length > 0
            gith.emit "file:delete", payload  if payload.files.deleted.length > 0
            gith.emit "file:modify", payload  if payload.files.modified.length > 0
            gith.emit "file:all", payload  if payload.files.all.length > 0

            # tagging?
            gith.emit "tag:add", payload  if payload.tag and originalPayload.created
            gith.emit "tag:delete", payload  if payload.tag and originalPayload.deleted
        return

    return


# inherit the EventEmitter2 stuff
util.inherits Gith, EventEmitter2

# expose the simpliyPayload method on gith()
Gith::simplifyPayload = (payload) ->
    payload = payload or {}
    branch = ""
    tag = ""
    rRef = /refs\/(tags|heads)\/(.*)$/

    # break out if it was a tag or branch and assign
    refMatches = (payload.ref or "").match(rRef)
    if refMatches
        branch = refMatches[2]  if refMatches[1] is "heads"
        tag = refMatches[2]  if refMatches[1] is "tags"

    # if branch wasn't found, use base_ref if available
    branch = payload.base_ref.replace(rRef, "$2")  if not branch and payload.base_ref
    simpler =
        original: payload
        files:
            all: []
            added: []
            deleted: []
            modified: []

        tag: tag
        branch: branch
        repo: (if payload.repository then (if payload.repository.owner? then (payload.repository.owner.name + "/" + payload.repository.name) else(payload.repository.name + "/" + payload.repository.name) ) else null)
        sha: payload.after
        time: (if payload.repository then payload.repository.pushed_at else null)
        urls:
            head: (if payload.head_commit then payload.head_commit.url else "")
            branch: ""
            tag: ""
            repo: (if payload.repository then payload.repository.url else null)
            compare: payload.compare

        reset: not payload.created and payload.forced
        pusher: (if payload.pusher then payload.pusher.name else null)
        owner: (if (payload.repository and payload.repository.owner) then payload.repository.owner.name else null)

    simpler.urls.branch = simpler.urls.branch + "/tree/" + branch  if branch
    simpler.urls.tag = simpler.urls.head  if tag

    # populate files for every commit
    (payload.commits or []).forEach (commit) ->

        # github label and simpler label ( make 'removed' deleted to be consistant )
        _.each
            added: "added"
            modified: "modified"
            removed: "deleted"
        , (s, g) ->
            simpler.files[s] = simpler.files[s].concat(commit[g])
            simpler.files.all = simpler.files.all.concat(commit[g])
            return

        return

    simpler


# todo: use github api to find what files were removed if the
# head was reset? maybe?

# the listen method - this gets added/bound in
# module.exports.create, fyi
listen = (eventaur, port) ->

    # are we changing ports?
    @port = port  if port
    throw new Error(".listen() requires a port to be set")  unless @port

    @server = http.createServer((req, res) ->
        data = ""
        if req.method is "POST"
            req.on "data", (chunk) ->
                data += chunk
                return

        req.on "end", ->
            debug JSON.stringify(JSON.parse(data), null, 2)
            payload = JSON.parse(data)
            eventaur.emit "payload", payload
            res.writeHead 200,
                "Content-type": "text/html"

            res.end()
            return

        return
    ).listen(port)
    return


# make require('gith')( 9001 ) work if someone really wants to
module.exports = (port) ->
    module.exports.create port


# make the preferred way of `require('gith').create( 9001 ) work
module.exports.create = (port) ->

    # make an event emitter to use for the hardcore stuff
    eventaur = new EventEmitter2(
        delimter: ":"
        maxListeners: 0
    )

    # return a function that
    #   a) holds its own server/port/whatever
    #   b) exposes a listen method
    #   c) is a function that returns a new Gith object
    ret = (map) ->

        # make a new Gith with a reference to this factory
        new Gith(eventaur, map)


    # add the listen method to the function - bind to ret
    # and send eventaur to it
    ret.listen = listen.bind(ret, eventaur)

    # expose ability to close http server
    ret.close = ->
        @server.close()
        return

    ret.payload = (payload) ->
        eventaur.emit "payload", payload
        return


    # if create was sent port, call listen automatically
    ret.listen port  if port

    # return the new function
    ret
