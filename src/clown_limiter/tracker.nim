## Copyright (C) 2022 Cnerd
## MIT License - Look at license.txt for details.

import db_sqlite, asyncdispatch, logging
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

    IntervalError* = object of CatchableError

var 
    db_write_lock : Lock ## define lock for db write operations
    cleaner_interval : int = 7200 ## interval in seconds at which the cleaner will be called. defaults to 7200 seconds

## initialize locks
initLock(db_write_lock)

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

proc setCleanerInterval*(interval : int) {.raises : [IntervalError].} =
    ## sets cleaner's interval in seconds
    ## will raise error if interval is less than 3600 seconds
    
    if interval < 3600:

        raise newException(IntervalError, "interval is less than 3600 seconds")

    cleaner_interval = interval

template log(level, msg : string) =

    when defined(logClown):
        ## use -d:logClown flag to enable logClown
        ## when enabled logClown will log error msgs to stdout

        {.cast(gcsafe).}:
            let logger = logger

        logger.log(level, msg)

template safeOp(lock : bool, body : untyped) =
    ## template to avoid exception errors from Db operations
    ## use -d:logClown flag to enable logClown which will log exception errors to stdout

    try:

        when lock:

            withLock db_write_lock:

                body

        else:

            body
    
    except DbError:

        log(lvlError, "Error Occured during clown limiter opt")
        log(lvlDebug, getCurrentExceptionMsg())
    
proc addIpToReqRate(ip : string) =
    ## creates new row on table requestrate if row with ip does not exist already
    
    if db.getValue(sql"SELECT EXISTS(SELECT NULL FROM requestrate WHERE ip = ?)", ip).parseBool():

        return
    
    safeOp true:

        discard db.insertID(
            sql"INSERT INTO requestrate (ip, calls, lastcalled) VALUES (?, ?, ?)", 
            ip, 1, int(epochTime())
        )

proc recordReqRate*(ip : string, calls : int) =
    ## records new request call

    safeOp true:

        db.exec(sql"UPDATE requestrate SET calls = ?, lastcalled = ? WHERE ip = ?", calls + 1, int(epochTime()), ip)

proc resetReqRate*(ip : string) : RequestRate {.discardable.} = 
    ## resets request call for ip to 1
    
    let epoch = epochTime()
    safeOp true:

        db.exec(sql"UPDATE requestrate SET calls = ?, lastcalled = ? WHERE ip = ?", 1, int(epoch), ip)
        return RequestRate(
            ip : ip,
            calls : 1,
            lastcalled : int(epoch)
        )

proc reqRate(ip : string) : RequestRate =
    ## gets requestrate data for ip
    
    safeOp false:

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

proc clean() {.async.} =
    ## clear stale ip rate records
    ## useful for keeping memory free expecially when application will be runned for a long time
    ## only call when cleanClown is defined
    
    when defined(cleanClown):
        
        while true:

            await sleepAsync(cleaner_interval * 1000)
            safeOp true:

                for row in db.getAllRows(sql "SELECT ip FROM requestrate WHERE lastcalled < ?", epochTime().int - cleaner_interval):

                    db.exec(sql "DELETE FROM requestrate WHERE ip = ?", row[0])

    else:

        discard

asyncCheck clean()

