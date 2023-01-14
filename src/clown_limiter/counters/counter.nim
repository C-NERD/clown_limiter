## Copyright (C) 2022 Cnerd
## MIT License - Look at LICENSE for details.

import ../datatype
import std / [locks, tables, exitprocs]
from std / times import epochTime
from std / sugar import `=>`

var 
    writeLock : Lock
    tracker {.guard : writeLock.} : Table[string, Table[string, tuple[calls, cyclepoch, lastcalled : int]]] ## table of regex endpoints containing 
    ## a table of ips which contains the tracker data

initLock(writeLock)
addExitProc(() => (deinitLock(writeLock))) ## deinit locks on exit
proc addIpToReqRate*(endpoint, ip : string) : tuple[calls, cyclepoch, lastcalled : int] {.gcsafe.} =

    {.cast(gcsafe).}:

        withLock writeLock:

            if endpoint notin tracker:

                let 
                    epoch = int(epochTime())
                    ipData = {ip : (calls : 1, cyclepoch : epoch, lastcalled : epoch)}.toTable()

                tracker[endpoint] = ipData
                result = ipData[ip]

            else:

                if ip notin tracker[endpoint]:

                    let epoch = int(epochTime())
                    tracker[endpoint][ip] = (calls : 1, cyclepoch : epoch, lastcalled : epoch)

                    result = tracker[endpoint][ip]

proc removeEndpoint*(endpoint : string) {.gcsafe.} =

    {.cast(gcsafe).}:

        withLock writeLock:

            if tracker.hasKey(endpoint):

                del tracker, endpoint

proc recordReqRate*(endpoint, ip : string, calls : int) {.gcsafe.} =

    {.cast(gcsafe).}:

        withLock writeLock:

            if endpoint in tracker:

                if ip in tracker[endpoint]:

                    tracker[endpoint][ip].calls = calls + 1
                    tracker[endpoint][ip].lastcalled = int(epochTime())

proc resetReqRate*(endpoint, ip : string) : tuple[calls, cyclepoch, lastcalled : int] {.discardable, gcsafe.} =

    {.cast(gcsafe).}:

        withLock writeLock:

            if endpoint in tracker:

                if ip in tracker[endpoint]:
                    
                    let epoch = int(epochTime())

                    tracker[endpoint][ip].calls = 2 ## it's 2 because this is called after rateStatus returns expire
                    ## the request on which rateStatus is called will then be the 1
                    tracker[endpoint][ip].cyclepoch = epoch
                    tracker[endpoint][ip].lastcalled = epoch

                    return (calls : 2, cyclepoch : epoch, lastcalled : epoch)

proc rateStatus*(endpoint, ip : string, rate, freq : int) : tuple[status : RateStatus, calls, resetime : int] {.gcsafe.} =
    
    let 
        reqRate : tuple[calls, cyclepoch, lastcalled : int] = block:

            var 
                reqRate : tuple[calls, cyclepoch, lastcalled : int]
                addip : bool = true
            {.cast(gcsafe).}:

                withLock writeLock:

                    if endpoint in tracker:
                        
                        if ip in tracker[endpoint]:

                            addip = false
                            reqRate = tracker[endpoint][ip]

            if addip:

                reqRate = addIpToReqRate(endpoint, ip)

            reqRate

        epoch = int(epochTime())
    
    if reqRate.cyclepoch + freq <= epoch:

        return (Expired, reqRate.calls, reqRate.cyclepoch + freq)

    elif reqRate.calls > rate and reqRate.cyclepoch + freq >= epoch:
        ## checks if ip has surpassed request limit
        
        return (Exceeded, reqRate.calls, reqRate.cyclepoch + freq)

    else:
        
        return (NotExceeded, reqRate.calls, reqRate.cyclepoch + freq)
