## Copyright (C) 2022 Cnerd
## MIT License - Look at license.txt for details.

import db_sqlite, logging
import std / exitprocs, locks
from strutils import isEmptyOrWhitespace, parseInt, parseBool
from times import epochTime
from sugar import `=>`

type

    RateStatus* {.pure.} = enum

        NotExceeded Exceeded Expired

    RequestRate* = object

        ip* : string
        calls*, lastcalled* : int

var ip_add_lock, rec_rate_lock, reset_rate_lock: Lock ## define locks for db write operations

## initialize locks
initLock(ip_add_lock)
initLock(rec_rate_lock)
initLock(reset_rate_lock)

let 
    logger = newConsoleLogger(fmtStr = "$levelname -> ")
    db : DbConn = open(":memory:", "", "", "")

addExitProc(() {.noconv.} => (if not db.isNil(): db.close()))

## create db schema
db.exec(sql"""
    CREATE TABLE IF NOT EXISTS requestrate(
        ip VARCHAR(50) NOT NULL,
        calls INTEGER NOT NULL,
        lastcalled INTEGER NOT NULL
    );
""")

template log(level, msg : string) =

    when defined(logClown):
        ## use -d:logClown flag to enable logClown
        ## when enabled logClown will log error msgs to stdout

        {.cast(gcsafe).}:
            let logger = logger

        logger.log(level, msg)

template safeOp(body : untyped) =
    ## template to avoid exception errors from Db operations
    ## use -d:logClown flag to enable logClown which will log exception errors to stdout

    try:

        body
    
    except DbError:

        log(lvlError, "Error Occured during clown limiter opt")
        log(lvlDebug, getCurrentExceptionMsg())
    
proc addIpToReqRate(ip : string) =
    ## creates new row on table requestrate if row with ip does not exist already
    
    if db.getValue(sql"SELECT EXISTS(SELECT NULL FROM requestrate WHERE ip = ?)", ip).parseBool():

        return
    
    ip_add_lock.acquire()
    discard db.insertID(
        sql"INSERT INTO requestrate (ip, calls, lastcalled) VALUES (?, ?, ?)", 
        ip, 1, int(epochTime())
    )

    ip_add_lock.release()

proc recordReqRate*(ip : string, calls : int) =
    ## records new request call

    safeOp:

        rec_rate_lock.acquire()
        db.exec(sql"UPDATE requestrate SET calls = ?, lastcalled = ? WHERE ip = ?", calls + 1, int(epochTime()), ip)

        rec_rate_lock.release()

proc resetReqRate*(ip : string) : RequestRate {.discardable.} = 
    ## resets request call for ip to 1
    
    let epoch = epochTime()
    safeOp:

        reset_rate_lock.acquire()
        db.exec(sql"UPDATE requestrate SET calls = ?, lastcalled = ? WHERE ip = ?", 1, int(epoch), ip)

        reset_rate_lock.release()
        return RequestRate(
            ip : ip,
            calls : 1,
            lastcalled : int(epoch)
        )

proc reqRate(ip : string) : RequestRate =
    ## gets requestrate data for ip
    
    safeOp:

        let row = db.getRow(sql"SELECT * FROM requestrate WHERE ip = ?", ip)
        if not row[0].isEmptyOrWhitespace():

            return RequestRate(
                ip : row[0],
                calls : row[1].parseInt(),
                lastcalled : row[2].parseInt()
            )

        addIpToReqRate(ip)

proc rateStatus*(ip : string, rate, freq : int) : tuple[status : RateStatus, calls : int] =

    let 
        req_rate = reqRate(ip)
        epoch = int(epochTime())

    if req_rate.calls >= rate and req_rate.lastcalled + freq >= epoch:
        ## checks if ip has surpassed request limit
        
        return (Exceeded, req_rate.calls)

    elif req_rate.lastcalled + freq < epoch:

        return (Expired, req_rate.calls)

    else:

        return (NotExceeded, req_rate.calls)

