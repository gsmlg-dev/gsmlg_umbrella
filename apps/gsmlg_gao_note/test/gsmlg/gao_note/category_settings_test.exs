defmodule GSMLG.GaoNote.CategorySettingsTest do
  use GSMLG.GaoNote.DataCase, async: true

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{CategorySetting, Label, LabelSetting, Note}

  setup do
    Repo.delete_all(CategorySetting)
    Repo.delete_all(Label)
    Repo.delete_all(LabelSetting)
    Repo.delete_all(Note)
    :ok
  end

  describe "save_category_settings/1" do
    test "fresh configuration defaults to an empty category list" do
      assert GaoNote.list_category_groups() == []
    end

    test "stores ordered key-wide and exact selectors and exposes configured counts" do
      project = label_setting_fixture(%{name: "project", description: "Project"})
      type = label_setting_fixture(%{name: "type"})

      assert {:ok, categories} =
               GaoNote.save_category_settings([
                 %{"label_setting_id" => project.id, "value" => "  "},
                 %{label_setting_id: type.id, value: " skill "},
                 %{label_setting_id: type.id, value: "agent"}
               ])

      assert Enum.map(categories, &{&1.position, &1.label_setting.name, &1.value}) == [
               {0, "project", nil},
               {1, "type", "skill"},
               {2, "type", "agent"}
             ]

      assert [
               %LabelSetting{name: "project", category_count: 1},
               %LabelSetting{name: "type", category_count: 2}
             ] = GaoNote.list_label_settings()
    end

    test "maps category database constraints through the changeset" do
      project = label_setting_fixture(%{name: "project"})
      type = label_setting_fixture(%{name: "type"})

      invalid_position =
        CategorySetting.changeset(struct(CategorySetting), %{
          label_setting_id: project.id,
          position: -1
        })

      assert "must be greater than or equal to 0" in errors_on(invalid_position).position

      assert {:ok, _categories} =
               GaoNote.save_category_settings([
                 %{label_setting_id: project.id},
                 %{label_setting_id: type.id, value: "skill"}
               ])

      assert {:error, duplicate_position} =
               struct(CategorySetting)
               |> CategorySetting.changeset(%{
                 label_setting_id: type.id,
                 value: "agent",
                 position: 0
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(duplicate_position).position

      assert {:error, duplicate_key_wide} =
               struct(CategorySetting)
               |> CategorySetting.changeset(%{
                 label_setting_id: project.id,
                 position: 2
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(duplicate_key_wide).label_setting_id

      assert {:error, duplicate_exact} =
               struct(CategorySetting)
               |> CategorySetting.changeset(%{
                 label_setting_id: type.id,
                 value: "skill",
                 position: 2
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(duplicate_exact).label_setting_id
    end

    test "rejects malformed and unknown selectors without replacing saved configuration" do
      project = label_setting_fixture(%{name: "project"})
      missing_id = Ecto.UUID.generate()

      assert {:ok, [_category]} =
               GaoNote.save_category_settings([%{label_setting_id: project.id}])

      assert {:error, :category_settings_must_be_a_list} =
               GaoNote.save_category_settings(%{})

      assert {:error, {:invalid_category_selector, 0, :must_be_a_map}} =
               GaoNote.save_category_settings(["project"])

      assert {:error, {:invalid_category_selector, 0, :invalid_label_setting_id}} =
               GaoNote.save_category_settings([%{label_setting_id: "not-a-uuid"}])

      assert {:error, {:unknown_category_label, ^missing_id}} =
               GaoNote.save_category_settings([%{label_setting_id: missing_id}])

      assert {:error, {:invalid_category_selector, 0, :invalid_value}} =
               GaoNote.save_category_settings([
                 %{label_setting_id: project.id, value: %{unexpected: true}}
               ])

      assert [%{label_setting_id: project_id, configured_value: nil}] =
               GaoNote.list_category_groups()

      assert project_id == project.id
    end

    test "validates typed values, rejects normalized duplicates, replaces, and clears" do
      project = label_setting_fixture(%{name: "project"})
      year = label_setting_fixture(%{name: "year", value_type: "year"})

      assert {:ok, categories} =
               GaoNote.save_category_settings([
                 %{label_setting_id: project.id},
                 %{label_setting_id: year.id, value: " 2026 "}
               ])

      assert Enum.map(categories, & &1.value) == [nil, "2026"]

      year_id = year.id

      assert {:error, {:invalid_category_value, ^year_id, ["must be YYYY"]}} =
               GaoNote.save_category_settings([
                 %{label_setting_id: year.id, value: "20x6"}
               ])

      assert Enum.map(GaoNote.list_category_groups(), & &1.configured_value) == [nil, "2026"]

      assert {:error, {:duplicate_category_selector, ^year_id, "2026"}} =
               GaoNote.save_category_settings([
                 %{label_setting_id: year.id, value: " 2026 "},
                 %{"label_setting_id" => year.id, "value" => "2026"}
               ])

      project_id = project.id

      assert [
               %{label_setting_id: ^project_id, configured_value: nil, position: 0},
               %{label_setting_id: ^year_id, configured_value: "2026", position: 1}
             ] = GaoNote.list_category_groups()

      assert {:ok, [%CategorySetting{position: 0, value: "2027"}]} =
               GaoNote.save_category_settings([
                 %{label_setting_id: year.id, value: "2027"}
               ])

      assert {:ok, []} = GaoNote.save_category_settings([])
      assert GaoNote.list_category_groups() == []
    end
  end

  describe "delete_label_setting/2" do
    test "protects configured keys until every category selector is removed" do
      type = label_setting_fixture(%{name: "type"})

      assert {:ok, _categories} =
               GaoNote.save_category_settings([
                 %{label_setting_id: type.id, value: "skill"},
                 %{label_setting_id: type.id, value: "agent"}
               ])

      type_id = type.id

      assert {:error,
              {:category_label_in_use,
               %{
                 label_setting_id: ^type_id,
                 name: "type",
                 message:
                   "Remove every category using this label from Category labels before deleting it."
               }}} =
               GaoNote.delete_label_setting(type)

      assert %LabelSetting{} = GaoNote.get_label_setting(type.id)

      assert {:ok, []} = GaoNote.save_category_settings([])
      assert {:ok, %LabelSetting{id: ^type_id}} = GaoNote.delete_label_setting(type)
      assert GaoNote.get_label_setting(type.id) == nil
    end
  end

  describe "list_category_groups/0" do
    test "aggregates only configured selectors from active nonblank labels in stable order" do
      project =
        label_setting_fixture(%{
          name: "project",
          description: "Project selector"
        })

      type = label_setting_fixture(%{name: "type"})
      score = label_setting_fixture(%{name: "score", value_type: "number"})
      empty = label_setting_fixture(%{name: "empty"})
      unconfigured = label_setting_fixture(%{name: "unconfigured"})

      assert {:ok, categories} =
               GaoNote.save_category_settings([
                 %{label_setting_id: project.id},
                 %{label_setting_id: type.id, value: "skill"},
                 %{label_setting_id: type.id, value: "agent"},
                 %{label_setting_id: score.id},
                 %{label_setting_id: empty.id}
               ])

      category_ids = Enum.map(categories, & &1.id)

      note_fixture(["project=alpha", "type=skill", "score=001.50", "unconfigured=visible"])
      note_fixture(["project=alpha"])
      note_fixture(["project=beta"])
      note_fixture(["project=omega"])
      note_fixture(["project"])

      nil_value_note = note_fixture([])

      assert {:ok, _label} =
               struct(Label)
               |> Label.changeset(%{
                 note_id: nil_value_note.id,
                 label_setting_id: project.id,
                 value: nil
               })
               |> Repo.insert()

      trashed = note_fixture(["project=trash-only", "type=agent", "score=2"])
      assert {:ok, _trashed} = GaoNote.delete_note(trashed, nil)

      assert {:ok, renamed_project} =
               GaoNote.update_label_setting(project, %{
                 name: "Renamed Project",
                 description: "Current description"
               })

      assert renamed_project.id == project.id

      assert [project_group, skill_group, agent_group, score_group, empty_group] =
               GaoNote.list_category_groups()

      assert Enum.map(
               [project_group, skill_group, agent_group, score_group, empty_group],
               & &1.id
             ) == category_ids

      assert %{
               label_setting_id: project_id,
               key: "renamed project",
               selector: "renamed project",
               configured_value: nil,
               description: "Current description",
               position: 0,
               values: [
                 %{value: "alpha", count: 2},
                 %{value: "beta", count: 1},
                 %{value: "omega", count: 1}
               ]
             } = project_group

      assert project_id == project.id

      assert %{
               label_setting_id: type_id,
               key: "type",
               selector: "type=skill",
               configured_value: "skill",
               position: 1,
               values: [%{value: "skill", count: 1}]
             } = skill_group

      assert type_id == type.id

      assert %{
               label_setting_id: ^type_id,
               key: "type",
               selector: "type=agent",
               configured_value: "agent",
               position: 2,
               values: []
             } = agent_group

      assert %{
               label_setting_id: score_id,
               configured_value: nil,
               position: 3,
               values: [%{value: "001.50", count: 1}]
             } = score_group

      assert score_id == score.id

      assert %{
               label_setting_id: empty_id,
               configured_value: nil,
               position: 4,
               values: []
             } = empty_group

      assert empty_id == empty.id
      refute Enum.any?(GaoNote.list_category_groups(), &(&1.label_setting_id == unconfigured.id))
    end
  end

  defp label_setting_fixture(attrs) do
    assert {:ok, label_setting} = GaoNote.create_label_setting(attrs)
    label_setting
  end

  defp note_fixture(labels) do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Category note #{System.unique_integer([:positive])}",
                 content: "Category content",
                 labels: labels
               },
               nil
             )

    note
  end
end

defmodule GSMLG.GaoNote.CategorySettingsConcurrencyTest do
  use GSMLG.GaoNote.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{CategorySetting, LabelSetting}

  @delay_function "gao_note_category_settings_test_delay"
  @delay_trigger "gao_note_category_settings_test_delay_trigger"

  test "concurrent full replacements both succeed and leave one whole ordered configuration" do
    fixture = prepare_concurrency_fixture()

    on_exit(fn -> restore_concurrency_fixture(fixture) end)
    install_delay_trigger()

    first_selectors = [
      %{label_setting_id: fixture.first.id},
      %{label_setting_id: fixture.second.id, value: "one"}
    ]

    second_selectors = [
      %{label_setting_id: fixture.second.id},
      %{label_setting_id: fixture.first.id, value: "two"},
      %{label_setting_id: fixture.first.id, value: "three"}
    ]

    {first_owner, first_save} = start_allowed_save(first_selectors)
    {second_owner, second_save} = start_allowed_save(second_selectors)

    send(first_save.pid, :save)
    send(second_save.pid, :save)

    results = Task.await_many([first_save, second_save], 10_000)

    stop_connection_owner(first_owner)
    stop_connection_owner(second_owner)

    assert Enum.all?(results, &match?({:ok, _categories}, &1))

    final_configuration =
      outside_sandbox(fn ->
        GaoNote.list_category_groups()
        |> Enum.map(&{&1.label_setting_id, &1.configured_value, &1.position})
      end)

    first_expected = [
      {fixture.first.id, nil, 0},
      {fixture.second.id, "one", 1}
    ]

    second_expected = [
      {fixture.second.id, nil, 0},
      {fixture.first.id, "two", 1},
      {fixture.first.id, "three", 2}
    ]

    assert final_configuration in [first_expected, second_expected]
  end

  defp prepare_concurrency_fixture do
    outside_sandbox(fn ->
      drop_delay_trigger()

      previous_categories =
        CategorySetting
        |> select(
          [category],
          map(category, [
            :id,
            :label_setting_id,
            :value,
            :position,
            :inserted_at,
            :updated_at
          ])
        )
        |> Repo.all()

      Repo.delete_all(CategorySetting)

      suffix = System.unique_integer([:positive])

      first =
        %LabelSetting{}
        |> LabelSetting.changeset(%{name: "concurrency-first-#{suffix}"})
        |> Repo.insert!()

      second =
        %LabelSetting{}
        |> LabelSetting.changeset(%{name: "concurrency-second-#{suffix}"})
        |> Repo.insert!()

      %{
        first: first,
        second: second,
        previous_categories: previous_categories
      }
    end)
  end

  defp install_delay_trigger do
    outside_sandbox(fn ->
      SQL.query!(
        Repo,
        """
        CREATE FUNCTION #{@delay_function}()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          PERFORM pg_sleep(0.15);
          RETURN NEW;
        END;
        $$;
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE TRIGGER #{@delay_trigger}
        BEFORE INSERT ON gao_note_category_settings
        FOR EACH ROW EXECUTE FUNCTION #{@delay_function}();
        """,
        []
      )
    end)
  end

  defp restore_concurrency_fixture(fixture) do
    outside_sandbox(fn ->
      drop_delay_trigger()
      Repo.delete_all(CategorySetting)

      if fixture.previous_categories != [] do
        Repo.insert_all(CategorySetting, fixture.previous_categories)
      end

      label_setting_ids = [fixture.first.id, fixture.second.id]

      Repo.delete_all(
        from(label_setting in LabelSetting, where: label_setting.id in ^label_setting_ids)
      )
    end)
  end

  defp drop_delay_trigger do
    SQL.query!(
      Repo,
      "DROP TRIGGER IF EXISTS #{@delay_trigger} ON gao_note_category_settings",
      []
    )

    SQL.query!(Repo, "DROP FUNCTION IF EXISTS #{@delay_function}()", [])
  end

  defp start_allowed_save(selectors) do
    parent = self()

    owner =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        send(parent, {:connection_ready, self()})

        receive do
          :stop -> Sandbox.checkin(Repo)
        end
      end)

    assert_receive {:connection_ready, owner_pid}, 2_000
    assert owner_pid == owner.pid

    save =
      Task.async(fn ->
        receive do
          :save -> GaoNote.save_category_settings(selectors)
        end
      end)

    assert :ok = Sandbox.allow(Repo, owner.pid, save.pid)
    {owner, save}
  end

  defp stop_connection_owner(owner) do
    send(owner.pid, :stop)
    assert :ok = Task.await(owner, 2_000)
  end

  defp outside_sandbox(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
    |> Task.await(10_000)
  end
end
