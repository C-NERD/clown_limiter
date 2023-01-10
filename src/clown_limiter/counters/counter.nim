## Copyright (C) 2022 Cnerd
## MIT License - Look at LICENSE for details.

import ../datatype
import std / [locks, tables, exitprocs]
from std / times import epochTime
from std / sugar import `=>`

var 
    writeLock : Lock
    tracker {.guard : writeLock.} : Table[string, tuple[calls, lastcalled : int]] ## to store ip address and number of calls made by address

initLock(writeLock)
addExitProc(() => (deinitLock(writeLock))) ## deinit locks on exit
proc addIpToReqRate*(ip : string) {.gcsafe.} =

    {.cast(gcsafe).}:

        withLock writeLock:

            if ip in tracker:

                return

            tracker[ip] = (calls : 1, lastcalled : int(epochTime()))

proc recordReqRate*(ip : string, calls : int) {.gcsafe.} =

    {.cast(gcsafe).}:

        withLock writeLock:

            if ip in tracker:

                tracker[ip].calls = calls + 1
                tracker[ip].lastcalled = int(epochTime())

proc resetReqRate*(ip : string) : tuple[calls, lastcalled : int] {.discardable, gcsafe.} =

    {.cast(gcsafe).}:

        withLock writeLock:
        
            if ip in tracker:

                tracker[ip].calls = 1
                tracker[ip].lastcalled = int(epochTime())

                return (calls : 1, lastcalled : tracker[ip].lastcalled)

proc rateStatus*(ip : string, rate, freq : int) : tuple[status : RateStatus, calls : int] {.gcsafe.} =

    let 
        reqRate : tuple[calls, lastcalled : int] = block:

            var 
                reqRate : tuple[calls, lastcalled : int] = (1, 0)
                addip : bool = true
            {.cast(gcsafe).}:

                withLock writeLock:

                    if ip in tracker:

                        addip = false
                        reqRate = tracker[ip]

            if addip:

                addIpToReqRate(ip)

            reqRate

        epoch = int(epochTime())

    if reqRate.calls >= rate and reqRate.lastcalled + freq >= epoch:
        ## checks if ip has surpassed request limit
        
        return (Exceeded, reqRate.calls)

    elif reqRate.lastcalled + freq < epoch:

        return (Expired, reqRate.calls)

    else:

        return (NotExceeded, reqRate.calls)
