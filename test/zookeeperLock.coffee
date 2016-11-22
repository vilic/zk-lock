{ expect } = require('chai')
promise = require('bluebird')
{ exec } = require('child_process')
zookeeper = require('node-zookeeper-client')
{ simple } = require('locators')
{ ZookeeperLock } = require('../build/zookeeperLock')
{ ZookeeperLockTimeoutError } = require('../build/exceptions')


#todo: set this to the path to your zkServer command to run tests
zkServerCommandPath = '~/Downloads/zookeeper-3.4.6/bin/zkServer.sh'

# todo: set this to the address of your zk server if non-standard
zkServer = 'localhost:2181'

zkClient = zookeeper.createClient(
  zkServer,
  {
    sessionTimeout: 15000
    spinDelay: 1000
    retries: 0
  }
)

simpleExec = (cmd, done) ->
  exec(cmd, (err, stdout, stderr) ->
    if err
      console.log(cmd)
      console.log('  stdout: ' + stdout)
      console.log('  stderr: ' + stderr)
      console.log('  exec err: ' + err)
      done(err)
      return
    done()
  )

describe 'sanity tests', ->
  it 'correctly strips paths from sequences', ->
    seq = ZookeeperLock.getSequenceNumber('lock-1')
    expect(seq).to.equal(1)


locator = simple()(zkServer)
config = {
  serverLocator: locator,
  pathPrefix: 'tests',
  sessionTimeout: 2000
}

describe 'Zookeeper lock', ->
  @timeout 5000

  before (testsComplete) ->

    simpleExec(zkServerCommandPath + ' start', (err) ->
      if err
        testsComplete(err)
        return
      ZookeeperLock.initialize(config);
      testsComplete()
    )

  afterEach (testComplete) ->
    @timeout 4000
    setTimeout(->
      testComplete()
    , 3000)

  after (testsComplete) ->
    @timeout 20000
    setTimeout(->
      simpleExec(zkServerCommandPath + ' stop', testsComplete)

      testsComplete()
    , 3000)


  it "can lock when nothing holds the lock", (testComplete) ->
    @timeout 10000
    ZookeeperLock.lock('test').then((lock) ->
      lock.on(ZookeeperLock.Signals.LOST, ->
        testComplete(new Error('failed, lock should not have been lost'))
      )
      lock.unlock().then(->
        testComplete();
      );
    ).catch((ex) ->
      testComplete(ex);
    )
    return

  it "can relock a lock that has been locked and unlocked", (testComplete) ->
    @timeout 20000
    ZookeeperLock.lock('test').then((lock) ->
      lock.on(ZookeeperLock.Signals.LOST, ->
        testComplete(new Error('failed, lock should not have been lost'))
      )
      lock.unlock().then(->
        setTimeout(->
          lock.lock('test').then(->
            lock.unlock().then(->
              testComplete()
            )
          )
        , 3000)
      );
    ).catch((ex) ->
      testComplete(ex);
    )
    return

  it "can get an unlocked lock and lock it", (testComplete) ->
    @timeout 10000
    try
      lock = ZookeeperLock.lockFactory()

      lock.lock('test').then(->
        lock.on(ZookeeperLock.Signals.LOST, ->
          testComplete(new Error('failed, lock should not have been lost'))
        )
        return lock.unlock()
      ).then(->
        testComplete()
      ).catch((err) ->
        testComplete(err)
      )
      return
    catch ex
      testComplete(ex)

  it "can not acquire a lock when something else holds it until it is released", (testComplete) ->
    @timeout 20000
    ZookeeperLock.lock('test').then((lock) ->
      lock.on(ZookeeperLock.Signals.LOST, ->
        testComplete(new Error('failed, lock should not have been lost'))
      )
      isUnlocked = false
      ZookeeperLock.lock('test').then((lock2) ->
        lock2.on(ZookeeperLock.Signals.LOST, ->
          testComplete(new Error('failed, lock should not have been lost'))
        )
        expect(isUnlocked).to.be.true
        return lock2.unlock()
      ).then(->
        testComplete()
      ).catch((err)->
        testComplete(err)
      )

      setTimeout(->
        isUnlocked = true
        lock.unlock().then(->
        )
      ,8000)
    )
    return

  it "can check if a lock exists for a key when lock exists", (testComplete) ->
    @timeout 20000
    ZookeeperLock.lock('test')
    .then((lock) ->
      lock.on(ZookeeperLock.Signals.LOST, ->
        testComplete(new Error('failed, lock should not have been lost'))
      )
      ZookeeperLock.checkLock('test')
      .then((result) ->
        expect(result).to.be.true
        return lock.unlock()
      ).then(->
        setTimeout(->
          ZookeeperLock.checkLock('test')
          .then((result2) ->
            expect(result2).to.be.false
            testComplete()
          ).catch((err) ->
            testComplete(err)
          )
        , 1000)
      ).catch((err)->
        testComplete(err)
      )
    ).catch((err) ->
      testComplete(err)
    )
    return

  it "can check if a lock exists for a key when lock doesn't exist", (testComplete) ->
    @timeout 20000
    ZookeeperLock.checkLock('noooooooo')
    .then((result) ->
      expect(result).to.be.false
      testComplete()
    ).catch((err) ->
      testComplete()
    )
    return

  it "can timeout if given a timeout to wait for a lock", (testComplete) ->
    @timeout 20000
    ZookeeperLock.lock('test')
    .then((lock) ->
      lock.on(ZookeeperLock.Signals.LOST, ->
        testComplete(new Error('failed, lock should not have been lost'))
      )
      ZookeeperLock.lock('test', 5000)
      .then((lock2)->
        lock2.unlock().then(->
          testComplete(new Error('did not timeout'))
        )
      ).catch(ZookeeperLockTimeoutError, (err)->
        expect(err.message).to.equal('timeout')
        lock.unlock().then(->
          testComplete()
        )
      ).catch((unknownErr) ->
        testComplete(unknownErr)
      )
    ).catch((err) ->
      testComplete(err)
    )
    return


  it "does not surrender the lock on disconnect if session does not expire", (testComplete) ->
    @timeout 20000
    ZookeeperLock.lock('test').then((lock) ->
      lock.on(ZookeeperLock.Signals.LOST, ->
        testComplete(new Error('failed, lock should not have been lost'))
      )

      setTimeout(->
        simpleExec(zkServerCommandPath + ' stop', ->
          setTimeout(->
            simpleExec(zkServerCommandPath + ' start', ->
              setTimeout(->
                lock.unlock().then(->
                  testComplete()
                )
              , 2000)
            )
          ,0)
        )
      ,0)
    )
    return

  it "releases the lock and emits the expired event on sessionTimeout", (testComplete) ->
    @timeout 20000
    ZookeeperLock.lock('test').then((lock) ->
      lock.on(ZookeeperLock.Signals.LOST, ->
        testComplete()
      )

      # burn up some time to force session to timeout
      burning = true
      ctime = 0
      time = process.hrtime()
      while burning
        nowTime = process.hrtime(time);
        if not (ctime == nowTime[0])
          ctime = nowTime[0]
        burning = nowTime[0] < 10
    )
    return

  it "can have concurrent lock holders if configured to allow it", (testComplete) ->
    multiConfig = {
      serverLocator: locator,
      pathPrefix: 'tests',
      sessionTimeout: 2000,
      maxConcurrentHolders: 2
    }
    lock1 = new ZookeeperLock(multiConfig)
    lock2 = new ZookeeperLock(multiConfig)
    lock3 = new ZookeeperLock(multiConfig)

    expectedSuccess = [lock1.lock('test'), lock2.lock('test')]
    promise.all(expectedSuccess).then((results) ->
      return lock3.lock('test', 1000).then(->
        throw Error('should not have been able to lock')
      ).catch(ZookeeperLockTimeoutError, (err) ->
        expect(err.message).to.equal('timeout')
      ).catch((err) ->
        testComplete(err)
      )
    ).catch((err) ->
      testComplete(err)
    ).finally(->
      promise.all([lock1.unlock(), lock2.unlock(), lock3.destroy()]).finally(->
        testComplete()
      )
    )
    return null

