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
        from std / nre import re
        from std / jsonutils import toJson

        addLimiterEndpoints(@[(nre.re"^/$", 50, 60), (nre.re"([/]|[A-z])+(.json)$", 50, 60)]) ## only limit the endpoint '/' and 
        ## endpoints ending with `.json` and limit those endpoints by 50 rates per 60 seconds. Do not call this in a threaded proc

        proc server() =

            routes:

                get "/":

                    resp "home page"

                get "/apiendpoint.json":

                    resp (status : true, msg : "opt successful").toJson()

                extend clown_limiter, "" ## can use second param of extend to further restrict clown limiter to certain endpoints

            runForever()

        server()
]##

import jester
import clown_limiter / datatype
import std / [locks, exitprocs]
from std / nre import contains, Regex
from std / sugar import `=>`
from std / options import isSome, get, some
from std / strformat import fmt

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

export datatype, locks, isSome, get, some, fmt, nre.contains

var 
    ruleLock* : Lock
    clownLimiterDataDoNotTouch* {.guard : ruleLock.} : seq[LimitRule] ## Do not mutate this variable directly 👀👀, 
    ## but instead use the addLimiterEndpoints proc

initLock(ruleLock)
addExitProc(() {.noconv.} => (deinitLock(ruleLock)))
proc addLimiterEndpoints*(rules : seq[LimitRule]) {.gcsafe.} =
    ## sets the data for api endpoints to be rate limited.
    ## makes sure that there are no multiple rules for a single regex endpoint
    
    {.cast(gcsafe).}:

        withLock ruleLock:

            var sortedRules : seq[LimitRule]
            for rule in rules:
                
                var duplicate : bool
                for sortrule in sortedRules:
                    
                    if sortrule.pattern == rule.pattern:

                        duplicate = true

                if not duplicate:

                    sortedRules.add(rule)

            clownLimiterDataDoNotTouch = sortedRules

proc addLimiterEndpoints*(rule : LimitRule) {.gcsafe.} =
    ## adds rule for api endpoints to be rate limited.
    ## makes sure that there are no multiple rules for a single regex endpoint
    
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

#[proc toRe(s: string, flags = {reStudy}) : re.Regex =  ## alias for re.re because jester macros do not accept DotExpr as params
    
    return re(s, flags)]#

router clown_limiter:

    before:
        ## rate limiting endpoint
        
        var rules : seq[LimitRule]
        {.cast(gcsafe).}:

            withLock ruleLock:

                rules = clownLimiterDataDoNotTouch

        var 
            checkRate : bool = false
            rate, freq : int
            endpoint : string
        let url = request.path()
        for rule in rules:

            if contains(url, rule.pattern):

                checkRate = true
                rate = rule.rate
                freq = rule.freq
                endpoint = rule.pattern.pattern
                break
        
        if checkRate:
            
            let 
                ip = request.ip()
                rateinfo = rateStatus(endpoint, ip, rate, freq)
            
            case rateinfo.status

            of Exceeded:

                halt Http429

            of NotExceeded:

                recordReqRate(endpoint, ip, rateinfo.calls)

            of Expired:

                resetReqRate(endpoint, ip)

            if result.headers.isSome():

                result.headers.get().add ("X-RateLimit-Limit", fmt"{rate}/{freq}s")
                result.headers.get().add ("X-RateLimit-Remaining", $(rate - rateinfo.calls))
                result.headers.get().add ("X-RateLimit-Reset", $rateinfo.resetime)

        