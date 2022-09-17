## Copyright (C) 2022 Cnerd
## MIT License - Look at LICENSE for details.

import tables
import std / locks
from times import epochTime

type

    RateStatus* {.pure.} = enum

        NotExceeded Exceeded Expired

    Tracker = object

        write_lock : Lock
        ip_data {.guard : write_lock.} : Table[string, tuple[calls, lastcalled : int]] ## to store ip address and number of calls made by address

var tracker* {.global.} : Tracker
initLock(tracker.write_lock)

proc addIpToReqRate*(ip : string) =

    withLock tracker.write_lock:

        if ip in tracker.ip_data:

            return

        tracker.ip_data[ip] = (calls : 1, lastcalled : int(epochTime()))

proc recordReqRate*(ip : string, calls : int) =

    withLock tracker.write_lock:

        if ip in tracker.ip_data:

            tracker.ip_data[ip].calls = calls + 1
            tracker.ip_data[ip].lastcalled = int(epochTime())

proc resetReqRate*(ip : string) : tuple[calls, lastcalled : int] {.discardable.} =

    withLock tracker.write_lock:

        if ip in tracker.ip_data:

            tracker.ip_data[ip].calls = 1
            tracker.ip_data[ip].lastcalled = int(epochTime())

            return (calls : 1, lastcalled : tracker.ip_data[ip].lastcalled)

proc rateStatus*(ip : string, rate, freq : int) : tuple[status : RateStatus, calls : int] =

    let 
        req_rate : tuple[calls, lastcalled : int] = block:

            var req_rate : tuple[calls, lastcalled : int] = (1, 0)
            withLock tracker.write_lock:

                req_rate = tracker.ip_data[ip]

            req_rate

        epoch = int(epochTime())

    if req_rate.calls >= rate and req_rate.lastcalled + freq >= epoch:
        ## checks if ip has surpassed request limit
        
        return (Exceeded, req_rate.calls)

    elif req_rate.lastcalled + freq < epoch:

        return (Expired, req_rate.calls)

    else:

        return (NotExceeded, req_rate.calls)
