# Copyright (C) 2022 Cnerd
# MIT License - Look at LICENSE for details.
##[
    Jester plugin for api rate limiting. This plugin is built to work on single and multithreaded jester servers. 
    This plugin makes use of a sqlite in memory instance, since this should not be bounded to the nim `gc` 
    and the db's write operations are controlled by locks to prevent data corruption. This plugin is safe 
    to be used in single and mutithreaded instances

    Examples
    ========

    .. code-block:: nim
        import threadpool, clown_limiter, jester
        from std / jsonutils import toJson

        addLimiterEndpoints(@[(re"([/]|[A-z])+(.json)$", 50, 60)]) ## only limit endpoints ending with `.json`
        ## and limit those endpoints by 50 rates per 60 seconds. Do not call this in a threaded proc

        proc server() =

            routes:

                get "/":

                    resp "home page"

                get "/userpage":

                    resp "userpage"

                post "/apiendpoint.json":

                    resp (status : true, msg : "opt successful").toJson()

                put "/apiendpoint.json":

                    resp (status : true, msg : "opt failed").toJson()

                extend clown_limiter, "" ## can use second param of extend to further restrict clown limiter 
                ## to certain endpoints

            runForever()

        spawn server()
        spawn server()
        sync()
]##

import jester
import clown_limiter / datatype
import std / [locks, exitprocs]
from std / re import re, contains, Regex
from std / sugar import `=>`

when not defined(useSqliteCounter):
    ## when not specified to use in memory sqlite to store tracking data

    import clown_limiter / counters / counter
    export counter

else:
    ## when specified to use in memory sqlite to store tracking data

    import clown_limiter / counters / sqlitecounter
    export sqlitecounter

type

    LimitRule* = tuple[pattern : Regex, rate, freq : int]

export datatype, re, locks

var 
    ruleLock* : Lock
    clownLimiterDataDoNotTouch* {.guard : ruleLock.} : seq[LimitRule] = @[
        (re".+", 50, 60)
    ] ## Do not mutate this variable directly 👀👀, but instead use the addLimiterEndpoints proc

initLock(ruleLock)
addExitProc(() {.noconv.} => (deinitLock(ruleLock)))
proc addLimiterEndpoints*(rules : seq[LimitRule]) {.gcsafe.} =
    ## sets the data for api endpoints to be rate limited.
    
    {.cast(gcsafe).}:

        withLock ruleLock:

            clownLimiterDataDoNotTouch = rules

proc addLimiterEndpoints*(rule : LimitRule) {.gcsafe.} =
    ## adds rule for api endpoints to be rate limited.
    ## if a rule for an endpoint already exists, it's replaced
    
    {.cast(gcsafe).}:

        withLock ruleLock:

            var insertPos : int = -1
            for pos in 0..<clownLimiterDataDoNotTouch.len():

                if clownLimiterDataDoNotTouch[pos].pattern == rule.pattern:

                    insertPos = pos

            if insertPos >= 0:

                clownLimiterDataDoNotTouch[insertPos] = rule

            else:

                clownLimiterDataDoNotTouch.add(rule)

router clown_limiter:

    before re".+":
        ## rate limiting endpoint
        
        var rules : seq[LimitRule]
        {.cast(gcsafe).}:

            withLock ruleLock:

                rules = clownLimiterDataDoNotTouch

        var 
            checkRate : bool = false
            rate, freq : int
        let url = request.path()
        for rule in rules:

            if contains(url, rule.pattern):

                checkRate = true
                rate = rule.rate
                freq = rule.freq
                break

        if checkRate:

            let 
                ip = request.ip()
                rateinfo = ip.rateStatus(rate, freq)

            case rateinfo.status

            of Exceeded:

                halt Http429

            of NotExceeded:

                ip.recordReqRate(rateinfo.calls)

            of Expired:

                ip.resetReqRate()
