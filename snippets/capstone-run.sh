# Disposable temporary databases are created automatically.
perl examples/36-processing-capstone.pl
perl examples/37-savepoints.pl
perl examples/38-retry-cancel.pl
perl examples/39-contention-benchmark.pl
prove -v examples/t/processing.t
# Optional Test2::Harness runner:
yath test -j2 examples/t/
