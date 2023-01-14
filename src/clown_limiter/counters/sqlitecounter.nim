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
CREATE TABLE IF NOT EXISTS ip(
    id INTEGER PRIMARY KEY,
    endpoint VARCHAR(30) NOT NULL,
    address VARCHAR(30) NOT NULL,
    calls INTEGER NOT NULL,
    cyclepoch INTEGER NOT NULL,
    lastcalled INTEGER NOT NULL
);"""
)

proc setCleanerInterval*(interval : int) {.raises : [IntervalError].} =
    ## sets cleaner's interval in seconds
    ## will raise error if interval is less than 3600 seconds
    
    if interval < 3600:

        raise newException(IntervalError, "interval is less than 3600 seconds")

    cleanerInterval = interval

proc addIpToReqRate(endpoint, ip : string) : tuple[calls, cyclepoch, lastcalled : int] {.gcsafe.} =
    ## creates new row on table endpoint and table ip. If row with ip does not exist already
    
    result.calls = 1
    withLock dbWriteLock:

        if db.getValue(sql"SELECT EXISTS(SELECT NULL FROM ip WHERE endpoint = ? AND address = ?)", endpoint, ip).parseBool():

            return

        let epoch = int(epochTime())
        discard db.insertID(sql "INSERT INTO ip (endpoint, address, calls, cyclepoch, lastcalled) VALUES (?, ?, ?, ?, ?);", 
            endpoint, ip, 1, epoch, epoch)

        result = (1, epoch, epoch)                

proc recordReqRate*(endpoint, ip : string, calls : int) =
    ## records new request call

    withLock dbWriteLock:

        if db.getValue(sql"SELECT EXISTS(SELECT NULL FROM ip WHERE endpoint = ? AND address = ?)", endpoint, ip).parseBool():

            let epoch = int(epochTime())
            db.exec(sql "UPDATE ip SET calls = ?, lastcalled = ? WHERE address = ?", calls + 1, epoch, ip)

proc resetReqRate*(endpoint, ip : string) : tuple[calls, cyclepoch, lastcalled : int] {.discardable.} = 
    ## resets request call for ip to 2
    
    withLock dbWriteLock:

        if db.getValue(sql"SELECT EXISTS(SELECT NULL FROM ip WHERE endpoint = ? AND address = ?)", endpoint, ip).parseBool():

            let epoch = int(epochTime())
            db.exec(sql "UPDATE ip SET calls = ?, cyclepoch = ?, lastcalled = ? WHERE address = ?", 2, epoch, epoch, ip)

            let row = db.getRow(sql "SELECT address, calls, cyclepoch, lastcalled FROM ip WHERE address = ?;", ip)
            return (
                calls : row[1].parseInt(), 
                cyclepoch : row[2].parseInt(), 
                lastcalled : row[3].parseInt()
            )

proc rateStatus*(endpoint, ip : string, rate, freq : int) : tuple[status : RateStatus, calls, resetime : int] =

    let 
        reqRate : tuple[calls, cyclepoch, lastcalled : int] = block:

            var 
                reqRate : tuple[calls, cyclepoch, lastcalled : int]
                addip : bool = true
            {.cast(gcsafe).}:

                withLock dbWriteLock:

                    if db.getValue(sql "SELECT EXISTS(SELECT NULL FROM ip WHERE endpoint = ? AND address = ?)", endpoint, ip).parseBool():
                        
                        addip = false

                        let row = db.getRow(sql "SELECT calls, cyclepoch, lastcalled FROM ip WHERE address = ?;", ip)
                        reqRate = (row[0].parseInt(), row[1].parseInt(), row[2].parseInt())

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

proc clean() {.async.} =
    ## clear stale ip rate records
    ## useful for keeping memory free expecially when application will be runned for a long time
        
    while true:

        await sleepAsync(cleanerInterval * 1000)
        withLock dbWriteLock:

            for row in db.getAllRows(sql "SELECT address FROM ip WHERE lastcalled < ?", epochTime().int - cleanerInterval):

                db.exec(sql "DELETE FROM ip WHERE address = ?", row[0])

asyncCheck clean()
