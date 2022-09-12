defmodule ObanTest do
  use Oban.Case, async: true

  alias Ecto.Multi

  @opts [repo: Repo, testing: :manual]

  describe "child_spec/1" do
    test "name is used as a default child id" do
      assert Supervisor.child_spec(Oban, []).id == Oban
      assert Supervisor.child_spec({Oban, name: :foo}, []).id == :foo
    end
  end

  describe "start_link/1" do
    test "name can be an arbitrary term" do
      opts = Keyword.put(@opts, :name, make_ref())

      assert {:ok, _} = start_supervised({Oban, opts})
    end

    test "name defaults to `Oban`" do
      assert {:ok, pid} = start_supervised({Oban, @opts})
      assert Oban.whereis(Oban) == pid
    end

    test "name must be unique" do
      name = make_ref()
      opts = Keyword.put(@opts, :name, name)

      {:ok, pid} = Oban.start_link(opts)
      {:error, {:already_started, ^pid}} = Oban.start_link(opts)
    end
  end

  describe "whereis/1" do
    test "returning the Oban root process's pid" do
      name_1 = make_ref()
      name_2 = make_ref()

      {:ok, oban_1} = start_supervised({Oban, Keyword.put(@opts, :name, name_1)})
      {:ok, oban_2} = start_supervised({Oban, Keyword.put(@opts, :name, name_2)})

      refute oban_1 == oban_2
      assert Oban.whereis(name_1) == oban_1
      assert Oban.whereis(name_2) == oban_2
    end

    test "returning nil if root process not found" do
      refute Oban.whereis(make_ref())
    end
  end

  describe "insert/2" do
    setup :start_supervised_oban

    test "inserting a single job", %{name: name} do
      assert {:ok, %Job{}} = Oban.insert(name, Worker.new(%{ref: 1}))
    end
  end

  describe "insert/4" do
    setup :start_supervised_oban

    test "inserting multiple jobs within a multi", %{name: name} do
      multi = Multi.new()
      multi = Oban.insert(name, multi, :job_1, Worker.new(%{ref: 1}))
      multi = Oban.insert(name, multi, "job-2", fn _ -> Worker.new(%{ref: 2}) end)
      multi = Oban.insert(name, multi, {:job, 3}, Worker.new(%{ref: 3}))
      assert {:ok, results} = Repo.transaction(multi)

      assert %{:job_1 => job_1, "job-2" => job_2, {:job, 3} => job_3} = results

      assert job_1.id
      assert job_2.id
      assert job_3.id
    end
  end

  describe "insert!/2" do
    setup :start_supervised_oban

    test "inserting a single job", %{name: name} do
      assert %Job{} = Oban.insert!(name, Worker.new(%{ref: 1}))
    end

    test "raising a changeset error when inserting fails", %{name: name} do
      assert_raise Ecto.InvalidChangesetError, fn ->
        Oban.insert!(name, Worker.new(%{ref: 1}, priority: -1))
      end
    end
  end

  describe "insert_all/2" do
    setup :start_supervised_oban

    test "inserting multiple jobs", %{name: name} do
      changesets = Enum.map(0..2, &Worker.new(%{ref: &1}, queue: "special", schedule_in: 10))
      jobs = Oban.insert_all(name, changesets)

      assert is_list(jobs)
      assert length(jobs) == 3

      [%Job{queue: "special", state: "scheduled"} = job | _] = jobs

      assert job.id
      assert job.args
      assert job.scheduled_at
    end

    test "inserting multiple jobs from a changeset wrapper", %{name: name} do
      wrap = %{changesets: [Worker.new(%{ref: 0}), Worker.new(%{ref: 1})]}

      [_job_1, _job_2] = Oban.insert_all(name, wrap)
    end

    test "handling empty changesets list from a wrapper", %{name: name} do
      assert [] = Oban.insert_all(name, %{changesets: []})
    end
  end

  describe "insert_all/3" do
    setup :start_supervised_oban

    test "inserting multiple jobs with additional options", %{name: name} do
      assert [%Job{}] = Oban.insert_all(name, [Worker.new(%{ref: 0})], timeout: 1_000)
    end
  end

  describe "insert_all/4" do
    setup :start_supervised_oban

    test "inserting multiple jobs within a multi", %{name: name} do
      changesets_1 = Enum.map(1..2, &Worker.new(%{ref: &1}))
      changesets_2 = Enum.map(3..4, &Worker.new(%{ref: &1}))
      changesets_3 = Enum.map(5..6, &Worker.new(%{ref: &1}))

      multi = Multi.new()
      multi = Oban.insert_all(name, multi, "jobs-1", changesets_1)
      multi = Oban.insert_all(name, multi, "jobs-2", changesets_2)
      multi = Multi.run(multi, "build-jobs-3", fn _, _ -> {:ok, changesets_3} end)
      multi = Oban.insert_all(name, multi, "jobs-3", & &1["build-jobs-3"])

      {:ok, %{"jobs-1" => jobs_1, "jobs-2" => jobs_2, "jobs-3" => jobs_3}} =
        Repo.transaction(multi)

      assert [%Job{}, %Job{}] = jobs_1
      assert [%Job{}, %Job{}] = jobs_2
      assert [%Job{}, %Job{}] = jobs_3
    end

    test "inserting multiple jobs from a changeset wrapper", %{name: name} do
      wrap = %{changesets: [Worker.new(%{ref: 0})]}

      multi = Multi.new()
      multi = Oban.insert_all(name, multi, "jobs-1", wrap)
      multi = Oban.insert_all(name, multi, "jobs-2", fn _ -> wrap end)

      {:ok, %{"jobs-1" => [_job_1], "jobs-2" => [_job_2]}} = Repo.transaction(multi)
    end

    test "handling empty changesets list from wrapper", %{name: name} do
      assert {:ok, %{jobs: []}} =
               name
               |> Oban.insert_all(Multi.new(), :jobs, %{changesets: []})
               |> Repo.transaction()
    end
  end

  defp start_supervised_oban(_context) do
    name = start_supervised_oban!(testing: :manual)

    {:ok, name: name}
  end
end
