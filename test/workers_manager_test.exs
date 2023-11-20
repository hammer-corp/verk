defmodule Verk.WorkersManagerTest do
  use ExUnit.Case, async: false
  import Mimic
  import Verk.WorkersManager
  alias Verk.{WorkersManager.State}

  setup :verify_on_exit!

  defmodule Repeater do
    use GenStage

    def init(pid) do
      {:consumer, pid, subscribe_to: [Verk.EventProducer]}
    end

    def handle_events(events, _from, pid) do
      Enum.each(events, fn event -> send(pid, event) end)
      {:noreply, [], pid}
    end
  end

  setup_all do
    {:ok, _} = GenStage.start_link(Verk.EventProducer, :ok, name: Verk.EventProducer)
    :ok
  end

  setup do
    pid = self()
    {:ok, _} = GenStage.start_link(Repeater, pid)
    table = :ets.new(:"queue_name.workers_manager", [:named_table, read_concurrency: true])
    {:ok, monitors: table}
  end

  describe "name/1" do
    test "returns workers manager name" do
      assert name("queue_name") == :"queue_name.workers_manager"
      assert name(:queue_name) == :"queue_name.workers_manager"
    end
  end

  describe "running_jobs/1" do
    test "list running jobs with jobs to list", %{monitors: monitors} do
      row = {self(), "job_id", "job", make_ref(), "start_time"}
      :ets.insert(monitors, row)

      assert running_jobs("queue_name") == [
               %{process: self(), job: "job", started_at: "start_time"}
             ]
    end

    test "list running jobs respecting the limit", %{monitors: monitors} do
      row1 = {self(), "job_id", "job", make_ref(), "start_time"}
      row2 = {self(), "job_id2", "job2", make_ref(), "start_time2"}
      :ets.insert(monitors, [row2, row1])

      assert running_jobs("queue_name", 1) == [
               %{process: self(), job: "job", started_at: "start_time"}
             ]
    end

    test "list running jobs with no jobs" do
      assert running_jobs("queue_name") == []
    end
  end

  describe "inspect_worker/2" do
    test "with no matching job_id" do
      assert inspect_worker("queue_name", "job_id") == {:error, :not_found}
    end

    test "with matching job_id", %{monitors: monitors} do
      row = {self(), "job_id", "job data", make_ref(), "start_time"}
      :ets.insert(monitors, row)

      {:ok, result} = inspect_worker("queue_name", "job_id")

      assert result[:job] == "job data"
      assert result[:process] == self()
      assert result[:started_at] == "start_time"

      expected = [:current_stacktrace, :initial_call, :reductions, :status]
      assert Enum.all?(expected, &Keyword.has_key?(result[:info], &1))
    end

    test "with matching job_id but process is gone", %{monitors: monitors} do
      pid = :erlang.list_to_pid('<3.57.1>')
      row = {pid, "job_id", "job data", make_ref(), "start_time"}
      :ets.insert(monitors, row)

      assert inspect_worker("queue_name", "job_id") == {:error, :not_found}
    end
  end

  describe "init/1" do
    test "inits and notifies if 'running'" do
      name = :workers_manager
      queue_name = "queue_name"
      queue_manager_name = "queue_manager_name"
      pool_name = "pool_name"
      pool_size = "size"
      timeout = Confex.get_env(:verk, :workers_manager_timeout)

      state = %State{
        queue_name: queue_name,
        queue_manager_name: queue_manager_name,
        pool_name: pool_name,
        pool_size: pool_size,
        monitors: :workers_manager,
        timeout: timeout,
        status: :running
      }

      expect(Verk.Manager, :status, fn ^queue_name -> :running end)

      assert init([name, queue_name, queue_manager_name, pool_name, pool_size]) == {:ok, state}

      assert_received :enqueue_inprogress
      assert_receive %Verk.Events.QueueRunning{queue: ^queue_name}
    end

    test "inits and does not notify ir paused" do
      name = :workers_manager
      queue_name = "queue_name"
      queue_manager_name = "queue_manager_name"
      pool_name = "pool_name"
      pool_size = "size"
      timeout = Confex.get_env(:verk, :workers_manager_timeout)

      state = %State{
        queue_name: queue_name,
        queue_manager_name: queue_manager_name,
        pool_name: pool_name,
        pool_size: pool_size,
        monitors: :workers_manager,
        timeout: timeout,
        status: :paused
      }

      expect(Verk.Manager, :status, fn ^queue_name -> :paused end)

      assert init([name, queue_name, queue_manager_name, pool_name, pool_size]) == {:ok, state}

      assert_received :enqueue_inprogress
    end
  end

  describe "handle_info/2 enqueue_inprogress" do
    test "enqueue_inprogress having no more jobs" do
      queue_manager_name = "queue_manager_name"
      state = %State{queue_manager_name: queue_manager_name}

      expect(Verk.QueueManager, :enqueue_inprogress, fn ^queue_manager_name -> :ok end)

      assert handle_info(:enqueue_inprogress, state) == {:noreply, state, 0}
      refute_receive :enqueue_inprogress
    end

    test "enqueue_inprogress having more jobs" do
      queue_manager_name = "queue_manager_name"
      state = %State{queue_manager_name: queue_manager_name}

      expect(Verk.QueueManager, :enqueue_inprogress, fn ^queue_manager_name -> :more end)

      assert handle_info(:enqueue_inprogress, state) == {:noreply, state}
      assert_receive :enqueue_inprogress
    end
  end

  describe "handle_call/3 pause" do
    test "with running status" do
      queue_name = "queue_name"
      state = %State{status: :running, queue_name: queue_name}

      assert handle_call(:pause, :from, state) == {:reply, :ok, %{state | status: :pausing}, 0}
      assert_receive %Verk.Events.QueuePausing{queue: ^queue_name}
    end

    test "with pausing status" do
      state = %State{status: :pausing}

      assert handle_call(:pause, :from, state) == {:reply, :ok, state}
      refute_receive %Verk.Events.QueuePausing{}
    end

    test "with paused status" do
      state = %State{status: :paused}

      assert handle_call(:pause, :from, state) == {:reply, :already_paused, state}
      refute_receive %Verk.Events.QueuePausing{}
    end
  end

  describe "handle_call/3 resume" do
    test "with running status" do
      state = %State{status: :running}

      assert handle_call(:resume, :from, state) == {:reply, :already_running, state}
      refute_receive %Verk.Events.QueueRunning{}
    end

    test "with pausing status" do
      queue_name = "queue_name"
      state = %State{status: :pausing, queue_name: queue_name}

      assert handle_call(:resume, :from, state) == {:reply, :ok, %{state | status: :running}, 0}
      assert_receive %Verk.Events.QueueRunning{queue: ^queue_name}
    end

    test "with paused status" do
      queue_name = "queue_name"
      state = %State{status: :paused, queue_name: queue_name}

      assert handle_call(:resume, :from, state) == {:reply, :ok, %{state | status: :running}, 0}
      assert_receive %Verk.Events.QueueRunning{queue: ^queue_name}
    end
  end

  describe "handle_info/2 timeout" do
    test "timeout with paused status" do
      state = %State{status: :paused}

      assert handle_info(:timeout, state) == {:noreply, state}
    end

    test "timeout with pausing status and jobs running", %{monitors: monitors} do
      row = {self(), "job_id", "job", make_ref(), "start_time"}
      :ets.insert(monitors, row)

      state = %State{status: :pausing, monitors: monitors}

      assert handle_info(:timeout, state) == {:noreply, state}
    end

    test "timeout with pausing status and no jobs running", %{monitors: monitors} do
      queue_name = "queue_name"
      state = %State{status: :pausing, monitors: monitors, queue_name: queue_name}

      assert handle_info(:timeout, state) == {:noreply, %{state | status: :paused}}

      assert_receive %Verk.Events.QueuePaused{queue: ^queue_name}
    end

    test "timeout with no free workers", %{monitors: monitors} do
      pool_name = "pool_name"
      state = %State{monitors: monitors, pool_name: pool_name, pool_size: 1}

      row = {self(), "job_id", "job", make_ref(), "start_time"}
      :ets.insert(monitors, row)

      expect(:poolboy, :status, fn "pool_name" -> {nil, 0, nil, nil} end)
      assert handle_info(:timeout, state) == {:noreply, state}
    end

    test "timeout with free workers and no jobs", %{monitors: monitors} do
      :rand.seed(:exs64, {1, 2, 3})
      queue_manager_name = :queue_manager_name
      timeout = 1000
      pool_name = "pool_name"

      state = %State{
        monitors: monitors,
        pool_name: pool_name,
        pool_size: 1,
        queue_manager_name: queue_manager_name,
        timeout: timeout
      }

      expect(:poolboy, :status, fn "pool_name" -> {nil, 1, nil, nil} end)
      expect(Verk.QueueManager, :dequeue, fn ^queue_manager_name, 1 -> [] end)

      assert handle_info(:timeout, state) == {:noreply, state, 1350}
    end

    test "timeout with free workers and jobs to be done", %{monitors: monitors} do
      :rand.seed(:exs64, {1, 2, 3})
      queue_manager_name = :queue_manager_name
      pool_name = :pool_name
      timeout = 1000
      worker = self()
      module = :module
      args = [:arg1, :arg2]
      job_id = "job_id"

      state = %State{
        monitors: monitors,
        pool_name: pool_name,
        pool_size: 1,
        queue_manager_name: queue_manager_name,
        timeout: timeout
      }

      job = %Verk.Job{class: module, args: args, jid: job_id}

      expect(Verk.QueueManager, :dequeue, fn ^queue_manager_name, 1 -> [:encoded_job] end)
      expect(Verk.Job, :decode, fn :encoded_job -> {:ok, job} end)
      expect(:poolboy, :status, fn ^pool_name -> {nil, 1, nil, nil} end)
      expect(:poolboy, :checkout, fn ^pool_name, false -> worker end)
      expect(Verk.Worker, :perform_async, fn ^worker, ^worker, ^job -> :ok end)

      assert handle_info(:timeout, state) == {:noreply, state, 1350}
      assert match?([{^worker, ^job_id, ^job, _, _}], :ets.lookup(monitors, worker))
      assert_receive %Verk.Events.JobStarted{job: ^job, started_at: _}
    end

    test "timeout with free workers and malformed job to be done", %{monitors: monitors} do
      :rand.seed(:exs64, {1, 2, 3})
      queue_manager_name = :queue_manager_name
      pool_name = :pool_name
      timeout = 1000
      worker = self()
      module = :module
      args = [:arg1, :arg2]
      job_id = "job_id"

      state = %State{
        monitors: monitors,
        pool_name: pool_name,
        pool_size: 1,
        queue_manager_name: queue_manager_name,
        timeout: timeout
      }

      _job = %Verk.Job{class: module, args: args, jid: job_id}

      expect(Verk.QueueManager, :dequeue, fn ^queue_manager_name, 1 -> [:encoded_job] end)
      expect(Verk.Job, :decode, fn :encoded_job -> {:error, "error"} end)
      expect(:poolboy, :status, fn ^pool_name -> {nil, 1, nil, nil} end)

      assert handle_info(:timeout, state) == {:noreply, state, 1350}
      # After receiving an error from Job.decode/1 and removing from the inprogress
      # queue, we expect the job to not be present in the worker table.
      assert match?([], :ets.lookup(monitors, worker))
    end
  end

  describe "handle_info/2 DOWN" do
    test "DOWN coming from dead worker with reason and stacktrace", %{monitors: monitors} do
      ref = make_ref()
      worker = self()
      pool_name = "pool_name"
      job = "job"
      queue_manager_name = "queue_manager_name"
      reason = :reason
      exception = RuntimeError.exception(inspect(reason))

      :ets.insert(monitors, {worker, "job_id", job, ref, "start_time"})

      state = %State{
        monitors: monitors,
        pool_name: pool_name,
        queue_manager_name: queue_manager_name
      }

      expect(Verk.Log, :fail, fn ^job, "start_time", ^worker -> :ok end)

      expect(Verk.QueueManager, :retry, fn ^queue_manager_name, ^job, ^exception, :stacktrace ->
        :ok
      end)

      expect(Verk.QueueManager, :ack, fn ^queue_manager_name, ^job -> :ok end)
      expect(:poolboy, :checkin, fn ^pool_name, ^worker -> :ok end)

      assert handle_info({:DOWN, ref, :_, worker, {reason, :stacktrace}}, state) ==
               {:noreply, state, 0}

      assert :ets.lookup(monitors, worker) == []

      assert_receive %Verk.Events.JobFailed{
        job: ^job,
        failed_at: _,
        stacktrace: :stacktrace,
        exception: ^exception
      }
    end

    test "DOWN coming from dead worker with reason and no stacktrace", %{monitors: monitors} do
      ref = make_ref()
      worker = self()
      pool_name = "pool_name"
      job = "job"
      queue_manager_name = "queue_manager_name"
      reason = :reason
      exception = RuntimeError.exception(inspect(reason))

      :ets.insert(monitors, {worker, "job_id", job, ref, "start_time"})

      state = %State{
        monitors: monitors,
        pool_name: pool_name,
        queue_manager_name: queue_manager_name
      }

      expect(Verk.Log, :fail, fn ^job, "start_time", ^worker -> :ok end)
      expect(Verk.QueueManager, :retry, fn ^queue_manager_name, ^job, ^exception, [] -> :ok end)
      expect(Verk.QueueManager, :ack, fn ^queue_manager_name, ^job -> :ok end)
      expect(:poolboy, :checkin, fn ^pool_name, ^worker -> :ok end)

      assert handle_info({:DOWN, ref, :_, worker, reason}, state) == {:noreply, state, 0}

      assert :ets.lookup(monitors, worker) == []

      assert_receive %Verk.Events.JobFailed{
        job: ^job,
        failed_at: _,
        stacktrace: [],
        exception: ^exception
      }
    end

    test "DOWN coming from dead worker with normal reason", %{monitors: monitors} do
      queue_manager_name = "queue_manager_name"
      pool_name = "pool_name"

      state = %State{
        monitors: monitors,
        pool_name: pool_name,
        queue_manager_name: queue_manager_name
      }

      worker = self()
      start_time = DateTime.utc_now()
      now = DateTime.utc_now()
      job = %Verk.Job{}
      finished_job = %Verk.Job{finished_at: now}
      job_id = "job_id"
      ref = make_ref()

      stub(Verk.Time, :now, fn -> now end)
      expect(Verk.QueueManager, :ack, fn ^queue_manager_name, ^job -> :ok end)

      :ets.insert(monitors, {worker, job_id, job, ref, start_time})
      assert handle_info({:DOWN, ref, :_, worker, :normal}, state) == {:noreply, state, 0}

      assert :ets.lookup(state.monitors, worker) == []

      assert_receive %Verk.Events.JobFinished{
        job: ^finished_job,
        started_at: ^start_time,
        finished_at: ^now
      }
    end

    test "DOWN coming from dead worker with failed reason", %{monitors: monitors} do
      ref = make_ref()
      worker = self()
      pool_name = "pool_name"
      job = "job"
      job_id = "job_id"
      queue_manager_name = "queue_manager_name"
      exception = RuntimeError.exception(":failed")

      :ets.insert(monitors, {worker, job_id, job, ref, "start_time"})

      state = %State{
        monitors: monitors,
        pool_name: pool_name,
        queue_manager_name: queue_manager_name
      }

      expect(Verk.Log, :fail, fn ^job, "start_time", ^worker -> :ok end)
      expect(Verk.QueueManager, :retry, fn ^queue_manager_name, ^job, ^exception, [] -> :ok end)
      expect(Verk.QueueManager, :ack, fn ^queue_manager_name, ^job -> :ok end)
      expect(:poolboy, :checkin, fn ^pool_name, ^worker -> :ok end)

      assert handle_info({:DOWN, ref, :_, worker, :failed}, state) == {:noreply, state, 0}

      assert :ets.lookup(monitors, worker) == []

      assert_receive %Verk.Events.JobFailed{
        job: ^job,
        failed_at: _,
        stacktrace: [],
        exception: ^exception
      }
    end
  end

  describe "handle_cast/2" do
    test "done having the worker registered", %{monitors: monitors} do
      queue_manager_name = "queue_manager_name"
      pool_name = "pool_name"

      state = %State{
        monitors: monitors,
        pool_name: pool_name,
        queue_manager_name: queue_manager_name
      }

      worker = self()
      now = DateTime.utc_now()
      job = %Verk.Job{}
      finished_job = %Verk.Job{finished_at: now}
      job_id = "job_id"

      stub(Verk.Time, :now, fn -> now end)
      expect(Verk.QueueManager, :ack, fn ^queue_manager_name, ^job -> :ok end)
      expect(:poolboy, :checkin, fn ^pool_name, ^worker -> :ok end)

      :ets.insert(monitors, {worker, job_id, job, make_ref(), now})
      assert handle_cast({:done, worker, job_id}, state) == {:noreply, state, 0}

      assert :ets.lookup(state.monitors, worker) == []
      assert_receive %Verk.Events.JobFinished{job: ^finished_job, finished_at: ^now}
    end

    test "cast failed coming from worker", %{monitors: monitors} do
      ref = make_ref()
      worker = self()
      pool_name = "pool_name"
      job = "job"
      job_id = "job_id"
      queue_manager_name = "queue_manager_name"
      exception = RuntimeError.exception("reasons")

      :ets.insert(monitors, {worker, job_id, job, ref, "start_time"})

      state = %State{
        monitors: monitors,
        pool_name: pool_name,
        queue_manager_name: queue_manager_name
      }

      expect(Verk.Log, :fail, fn ^job, "start_time", ^worker -> :ok end)

      expect(Verk.QueueManager, :retry, fn ^queue_manager_name, ^job, ^exception, :stacktrace ->
        :ok
      end)

      expect(Verk.QueueManager, :ack, fn ^queue_manager_name, ^job -> :ok end)
      expect(:poolboy, :checkin, fn ^pool_name, ^worker -> :ok end)

      assert handle_cast({:failed, worker, job_id, exception, :stacktrace}, state) ==
               {:noreply, state, 0}

      assert :ets.lookup(monitors, worker) == []

      assert_receive %Verk.Events.JobFailed{
        job: ^job,
        failed_at: _,
        stacktrace: :stacktrace,
        exception: ^exception
      }
    end
  end
end
