## Copyright (C) 2022 Cnerd
## MIT License - Look at LICENSE for details.

import ../datatype
import std / [exitprocs, locks, db_sqlite, asyncdispatch]
from strutils import isEmptyOrWhitespace, parseInt, parseBool
from times import epochTime
from sugar import `=>`

type

    IntervalError* = object of CatchableError

var 
    dbWriteLock : Lock ## define lock for db write operations
    cleanerInterval : int = 7200 ## interval in seconds at which the cleaner will be called. defaults to 7200 seconds

## initialize locks
initLock(dbWriteLock)

let db : DbConn = open(":memory:", "", "", "")
addExitProc(() {.noconv.} => (

    deinitLock(dbWriteLock);
    if not db.isNil(): 
        
        db.close()
    ))

## create db schema
db.exec(sql"""
CREATE TABLE IF NOT EXISTS requestrate(
    id INTEGER PRIMARY KEY,
    ip VARCHAR(50) NOT NULL,
    calls INTEGER NOT NULL,
    lastcalled INTEGER NOT NULL
);""")

proc setCleanerInterval*(interval : int) {.raises : [IntervalError].} =
    ## sets cleaner's interval in seconds
    ## will raise error if interval is less than 3600 seconds
    
    if interval < 3600:

        raise newException(IntervalError, "interval is less than 3600 seconds")

    cleanerInterval = interval

proc addIpToReqRate(ip : string) {.gcsafe.} =
    ## creates new row on table requestrate if row with ip does not exist already
    
    withLock dbWriteLock:

        if db.getValue(sql"SELECT EXISTS(SELECT NULL FROM requestrate WHERE ip = ?)", ip).parseBool():

            return

        discard db.insertID(
            sql"INSERT INTO requestrate (ip, calls, lastcalled) VALUES (?, ?, ?)", 
            ip, 1, int(epochTime())
        )

proc recordReqRate*(ip : string, calls : int) =
    ## records new request call

    withLock dbWriteLock:

        db.exec(
            sql"UPDATE requestrate SET calls = ?, lastcalled = ? WHERE ip = ?", 
            calls + 1, int(epochTime()), ip
        )

proc resetReqRate*(ip : string) : RequestRate {.discardable.} = 
    ## resets request call for ip to 1
    
    let epoch = epochTime()
    withLock dbWriteLock:

        db.exec(sql"UPDATE requestrate SET calls = ?, lastcalled = ? WHERE ip = ?", 1, int(epoch), ip)
        return RequestRate(
            ip : ip,
            calls : 1,
            lastcalled : int(epoch)
        )

proc reqRate(ip : string) : RequestRate =
    ## gets requestrate data for ip
    
    withLock dbWriteLock:

        let row = db.getRow(sql"SELECT * FROM requestrate WHERE ip = ?", ip)
        if not row[1].isEmptyOrWhitespace():

            return RequestRate(
                ip : row[1],
                calls : row[2].parseInt(),
                lastcalled : row[3].parseInt()
            )

    addIpToReqRate(ip)

proc rateStatus*(ip : string, rate, freq : int) : tuple[status : RateStatus, calls : int] =

    let 
        reqRate = reqRate(ip)
        epoch = int(epochTime())

    if reqRate.calls >= rate and reqRate.lastcalled + freq >= epoch:
        ## checks if ip has surpassed request limit
        
        return (Exceeded, reqRate.calls)

    elif reqRate.lastcalled + freq < epoch:

        return (Expired, reqRate.calls)

    else:

        return (NotExceeded, reqRate.calls)

proc clean() {.async.} =
    ## clear stale ip rate records
    ## useful for keeping memory free expecially when application will be runned for a long time
        
    while true:

        await sleepAsync(cleanerInterval * 1000)
        withLock dbWriteLock:

            for row in db.getAllRows(sql "SELECT ip FROM requestrate WHERE lastcalled < ?", epochTime().int - cleanerInterval):

                db.exec(sql "DELETE FROM requestrate WHERE ip = ?", row[0])

asyncCheck clean()
