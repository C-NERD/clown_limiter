### Clown limiter

Jester plugin for api rate limiting. This plugin is built to work on single and multithreaded jester servers. This plugin implements to types of trackers to limit api rate. The first tracker makes use of locks and nim's `ref type` for gcsafe and corruption free rate limiting. While the other makes use of a sqlite in memory instance which is not bounded to the nim `gc` and the db's write operations are controlled by locks to prevent data corruption hence it is also gcsafe and corruption free. This plugin is safe to be used in single and mutithreaded instances

### Example

```nim
import threadpool, clown_limiter, jester
from std / jsonutils import toJson

addLimiterEndpoints(@[(re"([/]|[A-z])+(.json)$", 50, 60)]) ## only limit endpoints ending with `.json`
## and limit those endpoints by 50 rates per 60 seconds. Do not call this in a threaded proc

proc server() =

    routes:

        get "/":

            resp "home page"

        get "/userpage":

            resp "userpage"

        post "/apiendpoint.json":

            resp (status : true, msg : "opt successful").toJson()

        put "/apiendpoint.json":

            resp (status : true, msg : "opt failed").toJson()

        extend clown_limiter, "" ## can use second param of extend to further restrict clown limiter to certain endpoints

    runForever()

spawn server()
spawn server()
sync()

```

### Compiler flags

-d:useSqliteTracker enables the use of in memory sqlite as tracker

-d:logClown enables logging of limiter related error messages to stdout

-d:clearClown enables clearing of stale rate records. Interval for clearing records can be set with `setCleanerInterval`

#### Note :

- The compiler flags will only take effect if `useSqliteTracker` is defined, because these flags are specific to the sqlitetracker.
- If `useSqliteTracker` is not defined clown_limiter will use the new tracker in `src/clown_limiter/tracker` as the default
- For version 0.3.0 upwards `useSqliteTracker` is now `useSqliteCounter` and the other 2 flags have been removed
