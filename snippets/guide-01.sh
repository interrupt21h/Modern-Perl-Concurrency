perl -V:useithreads -V:version
perl -Mthreads -Mthreads::shared -MThread::Queue \
  -MThread::Semaphore -e 'print "$threads::VERSION\n"'
perl -MThread::Semaphore -e 'print "$Thread::Semaphore::VERSION\n"'
perl -MDBD::mysql -e 'print DBD::mysql->VERSION, "\n"'
perldoc threads::shared
