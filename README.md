### Clown limiter

Jester plugin for api rate limiting. The plugin is built to work on single and multithreaded jester servers.

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

-d:logClown enables logging of limiter related error messages to stdout

-d:clearClown enables clearing of stale rate records. Interval for clearing records can be set with `setCleanerInterval`
