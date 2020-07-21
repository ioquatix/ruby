N = 1_000_000_000
require 'benchmark'
Benchmark.bm(10){|x|
  ct = Thread.current
  x.report("gv2gv"){
    ct.tls_test_gv2gv(N)
  }
  x.report("__thread"){
    ct.tls_test___thread(N)
  }
  x.report("getspecific"){
    ct.tls_test_pthread_getspecific(N)
  }
}

