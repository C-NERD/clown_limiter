### Clown limiter

Jester plugin for api rate limiting. This plugin is built to work on single and multithreaded jester servers. This plugin implements to types of trackers to limit api rate. The first tracker makes use of locks and nim's `ref type` for gcsafe and corruption free rate limiting. While the other makes use of a sqlite in memory instance which is not bounded to the nim `gc` and the db's write operations are controlled by locks to prevent data corruption hence it is also gcsafe and corruption free. This plugin is safe to be used in single and mutithreaded instances

### Example

```nim
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
```

### Compiler flags

-d:useSqliteTracker enables the use of in memory sqlite as the counter, else the normal counter will be used

### Using clown limiter with other http server libraries

```nim
import clown_limiter / datatype
import std / [locks, exitprocs, asynchttpserver, asyncdispatch]
from std / nre import contains, Regex
from std / asyncnet import getPeerAddr
from std / httpcore import newHttpHeaders
from std / sugar import `=>`
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

proc callBack(req : Request) {.async, gcsafe.} =

    try:

        var rules : seq[LimitRule]
        {.cast(gcsafe).}:

            withLock ruleLock:

                rules = clownLimiterDataDoNotTouch

        var 
            checkRate : bool = false
            rate, freq : int
            endpoint : string
            httpcode : HttpCode
        let url = req.url.path
        for rule in rules:
            
            if contains(url, rule.pattern):

                checkRate = true
                rate = rule.rate
                freq = rule.freq
                endpoint = rule.pattern.pattern
                break
        
        block limitValidation:
            
            if checkRate:
                
                let 
                    ip = req.client.getPeerAddr()[0]
                    rateinfo = rateStatus(endpoint, ip, rate, freq)
                
                case rateinfo.status

                of Exceeded:

                    await req.respond(Http429, "Too many requests")
                    httpcode = Http429
                    break limitValidation

                of NotExceeded:

                    recordReqRate(endpoint, ip, rateinfo.calls)

                of Expired:

                    resetReqRate(endpoint, ip)
            
                await req.respond(Http200, "Hello boss", newHttpHeaders(
                    @[
                        ("X-RateLimit-Limit", fmt"{rate}/{freq}s"),
                        ("X-RateLimit-Remaining", $(rate - rateinfo.calls)),
                        ("X-RateLimit-Reset", $rateinfo.resetime)
                    ]
                ))
                httpcode = Http200

            else:

                await req.respond(Http400, "Not Found")

        echo fmt"{req.reqMethod} :: {req.url.path} :: {httpcode}"

    except Exception as e:

        echo e.getStackTrace()
        await req.respond(Http500, "Server Error")

proc server*(ip : string, port : int) {.async.} =
    ## run http server
    
    echo fmt"Http server listening on {ip}:{port}"
    addLimiterEndpoints(@[(nre.re"^/$", 50, 60), (nre.re"([/]|[A-z])+(.json)$", 50, 60)])

    let server = newAsyncHttpServer()
    addExitProc(() {.closure.} => (
        echo "Stopping http server..."; 
        server.close()
    ))
    
    await server.serve(Port(port), callBack, ip)

asyncCheck server("0.0.0.0", 5000)
runForever()
```
