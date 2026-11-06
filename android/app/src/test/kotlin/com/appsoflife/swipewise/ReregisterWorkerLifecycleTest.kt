package com.appsoflife.swipewise

import android.app.Application
import android.content.Context
import android.os.Looper
import android.os.SystemClock
import androidx.work.Configuration
import androidx.work.Data
import androidx.work.ForegroundUpdater
import androidx.work.ListenableWorker.Result
import androidx.work.ProgressUpdater
import androidx.work.WorkInfo
import androidx.work.WorkerParameters
import androidx.work.impl.utils.futures.SettableFuture
import androidx.work.impl.utils.taskexecutor.WorkManagerTaskExecutor
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.DetectedActivity
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import kotlin.coroutines.EmptyCoroutineContext

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ReregisterWorkerLifecycleTest {
    private lateinit var context: Context
    private val running = mutableListOf<ControlledWorker>()

    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        shadowOf(context as Application).denyPermissions("android.permission.ACTIVITY_RECOGNITION")
        SystemClock.sleep(1_000_000L)
        BootIdentity.testBootCount = 1
        ActivityState.clear(context)
        context.getSharedPreferences("swipewise_reregister", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @After fun cleanup() {
        running.forEach { it.releaseWait.countDown() }
        running.forEach { it.future.get(5, TimeUnit.SECONDS) }
        ShadowLooper.idleMainLooper()
        ReregisterFallbackReceiver.cancel(context)
        BootIdentity.testBootCount = null
    }

    @Test fun `true callback succeeds and tears down once on main thread`() {
        val worker = startWorker()
        worker.engine.callback.success(true)
        val result = finish(worker)

        assertEquals(Result.success(), result)
        assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
        assertEquals(Looper.getMainLooper(), worker.prepareLooper)
        assertEquals(Looper.getMainLooper(), worker.engine.createLooper)
        assertEquals(Looper.getMainLooper(), worker.engine.runLooper)
        assertEquals(Looper.getMainLooper(), worker.engine.destroyLooper)
    }

    @Test fun `false error and missing channel callbacks retry with one teardown`() {
        val replies: List<(MethodChannel.Result) -> Unit> = listOf(
            { it.success(false) }, { it.error("synthetic_error", null, null) }, { it.notImplemented() },
        )
        for (reply in replies) {
            val worker = startWorker()
            reply(worker.engine.callback)
            assertEquals(Result.retry(), finish(worker))
            assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
        }
    }

    @Test fun `never callback timeout destroys engine and releases completion while recovery remains owed`() {
        val generation = PendingReregister.request(context, 0L, "os_recovery", force = true)
        val worker = startWorker()

        assertEquals(Result.retry(), finish(worker)) // Controlled wait returns at the production timeout boundary.
        assertTrue(PendingReregister.isPending(context))
        assertTrue(PendingReregister.forceRecovery(context))
        assertEquals(generation, PendingReregister.generation(context))
        assertEquals("Timeout must destroy its engine and release completion once", 1 to 1,
            worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `late callback after timeout cannot complete or destroy again`() {
        val worker = startWorker()
        assertEquals(Result.retry(), finish(worker))
        val terminalCounts = worker.engine.destroyCount to worker.completion.releases

        worker.engine.callback.success(true)

        assertEquals("Callback no longer owns a timed-out engine or completion", terminalCounts,
            worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `stop tears down engine and releases wait before callback or timeout`() {
        val generation = PendingReregister.request(context, 0L, "coverage")
        val worker = startWorker()

        worker.stop(WorkInfo.STOP_REASON_CANCELLED_BY_APP)
        ShadowLooper.idleMainLooper()

        assertTrue(worker.isStopped)
        assertTrue(PendingReregister.isPending(context))
        assertEquals(generation, PendingReregister.generation(context))
        assertEquals("Stop must destroy its engine and release completion once", 1 to 1,
            worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `late callback after stop cannot complete or destroy again`() {
        val worker = startWorker()
        worker.stop(WorkInfo.STOP_REASON_CANCELLED_BY_APP)
        ShadowLooper.idleMainLooper()
        val stoppedCounts = worker.engine.destroyCount to worker.completion.releases

        worker.engine.callback.success(true)

        assertEquals("Stopped callback cannot reacquire lifecycle ownership", stoppedCounts,
            worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `stop wins before success callback and cannot report successful work`() {
        val worker = startWorker()
        worker.stop(WorkInfo.STOP_REASON_CANCELLED_BY_APP)
        worker.engine.callback.success(true)

        assertTrue(worker.isStopped)
        assertEquals("A callback after stop must not turn cancelled work into success", Result.retry(), finish(worker))
        assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `completed success followed by stop cannot tear down or complete twice`() {
        val worker = startWorker()
        worker.engine.callback.success(true)
        assertEquals(Result.success(), finish(worker))

        worker.stop(WorkInfo.STOP_REASON_CANCELLED_BY_APP)
        ShadowLooper.idleMainLooper()

        assertTrue(worker.isStopped)
        assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `stop after successful callback before return cannot report success`() {
        val worker = startWorker()
        worker.engine.callback.success(true)
        worker.stop(WorkInfo.STOP_REASON_CANCELLED_BY_APP)

        assertEquals(Result.retry(), finish(worker))
        assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `duplicate terminal callbacks cannot destroy or release completion twice`() {
        val worker = startWorker()
        worker.engine.callback.success(true)
        worker.engine.callback.error("late_duplicate", null, null)

        assertEquals(Result.success(), finish(worker))
        assertEquals("Only the first terminal callback owns teardown and completion", 1 to 1,
            worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `initialization failure after engine creation retries and destroys engine`() {
        val worker = startWorker(runFailure = IllegalStateException("synthetic channel initialization failure"))

        assertEquals(Result.retry(), finish(worker))
        assertEquals(1, worker.created)
        assertEquals("An engine acquired before initialization failure still needs teardown", 1 to 1,
            worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `failure before engine creation retries without phantom teardown`() {
        val worker = startWorker(createFailure = IllegalStateException("synthetic loader failure"))

        assertEquals(Result.retry(), finish(worker))
        assertEquals(0, worker.created)
        assertEquals(0 to 1, worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `synchronous success followed by initialization throw completes only once`() {
        val worker = startWorker(runReply = {
            it.success(true)
            throw IllegalStateException("synthetic throw after synchronous reply")
        })

        assertEquals(Result.success(), finish(worker))
        assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
        assertEquals(Looper.getMainLooper(), worker.engine.destroyLooper)
    }

    @Test fun `throwing engine destruction still releases completion once`() {
        val worker = startWorker(destroyFailure = IllegalStateException("synthetic destroy failure"))

        worker.engine.callback.success(true)
        worker.engine.callback.notImplemented()

        assertEquals(Result.success(), finish(worker))
        assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `timeout before main initialization cannot create a new engine`() {
        val worker = startWorker(drainMain = false)

        assertEquals(Result.retry(), finish(worker))

        assertEquals(0, worker.created)
        assertEquals(0 to 1, worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `interrupted wait restores interrupt flag tears down and ignores late callback`() {
        val generation = PendingReregister.request(context, 0L, "os_recovery", force = true)
        val worker = startWorker()

        worker.thread.interrupt()

        assertEquals(Result.retry(), worker.future.get(5, TimeUnit.SECONDS))
        ShadowLooper.idleMainLooper()
        assertTrue(worker.waitInterrupted)
        assertTrue(worker.interruptedOnReturn)
        assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
        assertEquals(Looper.getMainLooper(), worker.engine.destroyLooper)
        assertTrue(PendingReregister.isPending(context))
        assertTrue(PendingReregister.forceRecovery(context))
        assertEquals(generation, PendingReregister.generation(context))
        worker.engine.callback.success(true)
        assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `background stop owns cancellation before queued main cleanup`() {
        val worker = startWorker()
        val stop = Thread { worker.stop(WorkInfo.STOP_REASON_CANCELLED_BY_APP) }
        stop.start()
        stop.join(5000L)
        assertFalse(stop.isAlive)
        assertTrue(worker.isStopped)
        assertEquals(0, worker.engine.destroyCount)

        worker.engine.callback.success(true)

        assertEquals(Result.retry(), finish(worker))
        assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
        assertEquals(Looper.getMainLooper(), worker.engine.destroyLooper)
    }

    @Test fun `reentrant stop during engine creation destroys acquired engine without running Dart`() {
        val worker = startWorker(onCreate = { it.stop(WorkInfo.STOP_REASON_CANCELLED_BY_APP) })

        assertEquals(Result.retry(), finish(worker))
        assertEquals(1, worker.created)
        assertNull(worker.engine.runLooper)
        assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
        assertEquals(Looper.getMainLooper(), worker.engine.destroyLooper)
    }

    @Test fun `timeout during engine creation destroys acquired engine without running Dart`() {
        val worker = startWorker(onCreate = {
            it.releaseWait.countDown()
            assertEquals(Result.retry(), it.future.get(5, TimeUnit.SECONDS))
        })

        assertEquals(Result.retry(), finish(worker))
        assertEquals(1, worker.created)
        assertNull(worker.engine.runLooper)
        assertEquals(1 to 1, worker.engine.destroyCount to worker.completion.releases)
        assertEquals(Looper.getMainLooper(), worker.engine.destroyLooper)
    }

    @Test fun `engine preparation failure releases completion without creating engine`() {
        val worker = startWorker(prepareFailure = IllegalStateException("synthetic injector failure"))

        assertEquals(Result.retry(), finish(worker))
        assertEquals(0, worker.created)
        assertEquals(0 to 1, worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `stop during loader preparation cannot construct an engine`() {
        val worker = startWorker(onPrepare = { it.stop(WorkInfo.STOP_REASON_CANCELLED_BY_APP) })

        assertEquals(Result.retry(), finish(worker))
        assertEquals(1, worker.prepared)
        assertEquals(Looper.getMainLooper(), worker.prepareLooper)
        assertEquals(0, worker.created)
        assertEquals(0 to 1, worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `timeout during loader preparation cannot construct an engine`() {
        val worker = startWorker(onPrepare = {
            it.releaseWait.countDown()
            assertEquals(Result.retry(), it.future.get(5, TimeUnit.SECONDS))
        })

        assertEquals(Result.retry(), finish(worker))
        assertEquals(1, worker.prepared)
        assertEquals(0, worker.created)
        assertEquals(0 to 1, worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `already stopped worker does not initialize or report success`() {
        val worker = ControlledWorker(context, parameters())
        worker.stop(WorkInfo.STOP_REASON_CANCELLED_BY_APP)

        assertEquals(Result.retry(), worker.doWork())
        assertEquals(0, worker.prepared)
        assertEquals(0, worker.created)
        assertEquals(0 to 0, worker.engine.destroyCount to worker.completion.releases)
    }

    @Test fun `stop before main initialization cannot create a new engine`() {
        val worker = startWorker(drainMain = false)
        worker.stop(WorkInfo.STOP_REASON_CANCELLED_BY_APP)

        ShadowLooper.idleMainLooper()

        assertTrue(worker.isStopped)
        assertEquals("Queued main-thread initialization must not outlive stopped work", 0, worker.created)
        assertEquals(Result.retry(), finish(worker))
    }

    @Test fun `driving defers without constructing engine and preserves forced recovery`() {
        PendingReregister.request(context, 0L, "os_recovery", force = true)
        ActivityState.set(context, DetectedActivity.IN_VEHICLE, ActivityTransition.ACTIVITY_TRANSITION_ENTER,
            SystemClock.elapsedRealtimeNanos(), System.currentTimeMillis())
        val worker = ControlledWorker(context, parameters())

        assertEquals(Result.success(), worker.doWork())
        assertEquals(0, worker.prepared)
        assertEquals(0, worker.created)
        assertTrue(PendingReregister.isPending(context))
        assertTrue(PendingReregister.forceRecovery(context))
    }

    private fun startWorker(
        drainMain: Boolean = true,
        runFailure: Exception? = null,
        createFailure: Exception? = null,
        destroyFailure: Exception? = null,
        prepareFailure: Exception? = null,
        runReply: ((MethodChannel.Result) -> Unit)? = null,
        onCreate: ((ControlledWorker) -> Unit)? = null,
        onPrepare: ((ControlledWorker) -> Unit)? = null,
    ): ControlledWorker {
        val worker = ControlledWorker(context, parameters())
        worker.engine.runFailure = runFailure
        worker.engine.destroyFailure = destroyFailure
        worker.engine.runReply = runReply
        worker.createFailure = createFailure
        worker.prepareFailure = prepareFailure
        worker.onCreate = onCreate
        worker.onPrepare = onPrepare
        worker.future = FutureTask {
            val result = worker.doWork()
            worker.interruptedOnReturn = Thread.currentThread().isInterrupted
            result
        }
        running.add(worker)
        worker.thread = Thread(worker.future, "reregister-worker-test")
        worker.thread.start()
        assertTrue("Worker did not reach controlled wait", worker.waiting.await(5, TimeUnit.SECONDS))
        if (drainMain) ShadowLooper.idleMainLooper()
        return worker
    }

    private fun finish(worker: ControlledWorker): Result {
        worker.releaseWait.countDown()
        val result = worker.future.get(5, TimeUnit.SECONDS)
        ShadowLooper.idleMainLooper()
        return result
    }

    private fun parameters(): WorkerParameters {
        val direct = Executor { it.run() }
        val configuration = Configuration.Builder().setExecutor(direct).setTaskExecutor(direct).build()
        return WorkerParameters(
            UUID.randomUUID(), Data.EMPTY, emptyList(), WorkerParameters.RuntimeExtras(), 0, 0,
            direct, EmptyCoroutineContext, WorkManagerTaskExecutor(direct), configuration.workerFactory,
            ProgressUpdater { _, _, _ -> SettableFuture.create<Void>().apply { set(null) } },
            ForegroundUpdater { _, _, _ -> SettableFuture.create<Void>().apply { set(null) } },
        )
    }

    private class RecordingLatch : CountDownLatch(1) {
        var releases = 0
        override fun countDown() { releases++; super.countDown() }
    }

    private class FakeEngine : ReregisterEngine {
        lateinit var callback: MethodChannel.Result
        var runFailure: Exception? = null
        var destroyFailure: Exception? = null
        var runReply: ((MethodChannel.Result) -> Unit)? = null
        var createLooper: Looper? = null
        var runLooper: Looper? = null
        var destroyLooper: Looper? = null
        var destroyCount = 0
        override fun run(result: MethodChannel.Result) {
            runLooper = Looper.myLooper()
            runFailure?.let { throw it }
            callback = result
            runReply?.invoke(result)
        }
        override fun destroy() {
            destroyCount++
            destroyLooper = Looper.myLooper()
            destroyFailure?.let { throw it }
        }
    }

    private class ControlledWorker(context: Context, params: WorkerParameters) : ReregisterWorker(context, params) {
        val engine = FakeEngine()
        val completion = RecordingLatch()
        val waiting = CountDownLatch(1)
        val releaseWait = CountDownLatch(1)
        lateinit var future: FutureTask<Result>
        lateinit var thread: Thread
        var interruptedOnReturn = false
        var waitInterrupted = false
        var prepared = 0
        var prepareLooper: Looper? = null
        var created = 0
        var createFailure: Exception? = null
        var prepareFailure: Exception? = null
        var onCreate: ((ControlledWorker) -> Unit)? = null
        var onPrepare: ((ControlledWorker) -> Unit)? = null
        override fun completionLatch(): CountDownLatch = completion
        override fun prepareEngine(): () -> ReregisterEngine {
            prepared++
            prepareLooper = Looper.myLooper()
            prepareFailure?.let { throw it }
            onPrepare?.invoke(this)
            return {
                createFailure?.let { throw it }
                created++
                engine.createLooper = Looper.myLooper()
                onCreate?.invoke(this)
                engine
            }
        }
        override fun awaitCompletion(latch: CountDownLatch) {
            assertSame(completion, latch)
            waiting.countDown()
            try {
                check(releaseWait.await(5, TimeUnit.SECONDS)) { "Test did not release controlled wait" }
            } catch (e: InterruptedException) {
                waitInterrupted = true
                throw e
            }
        }
    }
}
