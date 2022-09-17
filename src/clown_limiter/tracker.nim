## Copyright (C) 2022 Cnerd
## MIT License - Look at LICENSE for details.

import tables
import std / locks
from times import epochTime

type

    RateStatus* {.pure.} = enum

        NotExceeded Exceeded Expired

var 
    write_lock : Lock
    tracker : Table[string, tuple[calls, lastcalled : int]] ## to store ip address and number of calls made by address
    tracker_addr = addr(tracker)

initLock(write_lock)

proc addIpToReqRate*(ip : string) {.gcsafe.} =

    var ip_data {.guard : write_lock.} = cast[ref Table[string, tuple[calls, lastcalled : int]]](tracker_addr)
    withLock write_lock:

        if ip in ip_data:

            return

        ip_data[ip] = (calls : 1, lastcalled : int(epochTime()))

proc recordReqRate*(ip : string, calls : int) {.gcsafe.} =

    var ip_data {.guard : write_lock.} = cast[ref Table[string, tuple[calls, lastcalled : int]]](tracker_addr)
    withLock write_lock:

        if ip in ip_data:

            ip_data[ip].calls = calls + 1
            ip_data[ip].lastcalled = int(epochTime())

proc resetReqRate*(ip : string) : tuple[calls, lastcalled : int] {.discardable, gcsafe.} =

    var ip_data {.guard : write_lock.} = cast[ref Table[string, tuple[calls, lastcalled : int]]](tracker_addr)
    withLock write_lock:
        
        if ip in ip_data:

            ip_data[ip].calls = 1
            ip_data[ip].lastcalled = int(epochTime())

            return (calls : 1, lastcalled : ip_data[ip].lastcalled)

proc rateStatus*(ip : string, rate, freq : int) : tuple[status : RateStatus, calls : int] {.gcsafe.} =

    let 
        ip_data {.guard : write_lock.} = cast[ref Table[string, tuple[calls, lastcalled : int]]](tracker_addr)
        req_rate : tuple[calls, lastcalled : int] = block:

            var 
                req_rate : tuple[calls, lastcalled : int] = (1, 0)
                addip : bool = true
            withLock write_lock:

                if ip in ip_data:

                    addip = false
                    req_rate = ip_data[ip]

            if addip:

                addIpToReqRate(ip)

            req_rate

        epoch = int(epochTime())

    if req_rate.calls >= rate and req_rate.lastcalled + freq >= epoch:
        ## checks if ip has surpassed request limit
        
        return (Exceeded, req_rate.calls)

    elif req_rate.lastcalled + freq < epoch:

        return (Expired, req_rate.calls)

    else:

        return (NotExceeded, req_rate.calls)