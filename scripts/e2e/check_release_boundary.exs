defmodule YellowDog.ReleaseBoundary do
  def check!(root) do
    products = [:yellow_dog_management, :yellow_dog_worker]
    expected_apps = products ++ [:yellow_dog_config_spec, :abyss, :ex_dns]
    config = Mix.Project.config()

    require!(
      Enum.sort(Map.keys(Mix.Project.apps_paths())) == Enum.sort(expected_apps),
      "unsupported umbrella applications"
    )

    require!(
      Enum.sort(Keyword.keys(config[:releases])) == Enum.sort(products),
      "supported business releases must be exactly Management and Worker"
    )

    contracts =
      Enum.map(products, fn product ->
        release_config = config[:releases][product]

        require!(
          release_config[:applications] == [{product, :permanent}],
          "#{product}: mixed business startup"
        )

        require!(
          release_config[:runtime_config_path] == "apps/#{product}/config/runtime.exs",
          "#{product}: shared or legacy runtime configuration"
        )

        directory = Path.join(root, Atom.to_string(product))

        require!(
          !File.exists?(Path.join(directory, "bin/yellow_dog_cli")),
          "obsolete CLI packaged"
        )

        [_, version] =
          directory |> Path.join("releases/start_erl.data") |> File.read!() |> String.split()

        manifest = Path.join(directory, "releases/#{version}/#{product}.rel")
        {:ok, [{:release, {release_name, _}, _, applications}]} = :file.consult(manifest)
        require!(to_string(release_name) == Atom.to_string(product), "release identity mismatch")
        names = Enum.map(applications, &elem(&1, 0))

        require!(
          match?({^product, _, :permanent}, Enum.find(applications, &(elem(&1, 0) == product))),
          "#{product}: startup mode mismatch"
        )

        specifications =
          directory
          |> Path.join("lib/*/ebin/*.app")
          |> Path.wildcard()
          |> Map.new(fn path ->
            {:ok, [{:application, name, specification}]} = :file.consult(path)
            {name, {path, specification}}
          end)

        require!(
          Enum.sort(names) == Enum.sort(Map.keys(specifications)),
          "#{product}: unmanifested or missing packaged application"
        )

        business_apps =
          Enum.filter(
            names,
            &(&1 == :yellow_dog or String.starts_with?(Atom.to_string(&1), "yellow_dog_"))
          )

        require!(
          Enum.sort(business_apps) == Enum.sort([product, :yellow_dog_config_spec]),
          "#{product}: another business runtime is packaged"
        )

        forbidden =
          if product == :yellow_dog_management do
            [:abyss, :ex_dns, :ex_dhcp, :concord, :mnesia]
          else
            [
              :ecto,
              :ecto_sql,
              :postgrex,
              :db_connection,
              :phoenix,
              :phoenix_live_view,
              :plug,
              :bandit,
              :concord,
              :mnesia
            ]
          end

        require!(Enum.all?(names, &(&1 not in forbidden)), "#{product}: forbidden dependency")

        {_, product_specification} = Map.fetch!(specifications, product)

        {expected_callback, forbidden_modules} =
          if product == :yellow_dog_management do
            {YellowDog.Management.Application,
             [
               "Elixir.YellowDog.Worker",
               "Elixir.YellowDog.Netboot",
               "Elixir.YellowDog.Identity",
               "Elixir.YellowDogIdentity"
             ]}
          else
            {YellowDog.Worker.Application,
             ["Elixir.YellowDog.Management", "Elixir.YellowDog.ManagementUI"]}
          end

        require!(
          product_specification[:mod] == {expected_callback, []},
          "#{product}: application callback mismatch"
        )

        packaged_modules =
          directory
          |> Path.join("lib/*/ebin/*.beam")
          |> Path.wildcard()
          |> Enum.map(&Path.basename(&1, ".beam"))

        require!(
          Enum.all?(packaged_modules, fn module ->
            Enum.all?(forbidden_modules, fn forbidden_module ->
              module != forbidden_module and
                !String.starts_with?(module, forbidden_module <> ".")
            end)
          end),
          "#{product}: misplaced execution module"
        )

        {contract_path, contract} = Map.fetch!(specifications, :yellow_dog_config_spec)
        require!(!Keyword.has_key?(contract, :mod), "ConfigSpec must not start a runtime")

        require!(
          Enum.all?(
            contract[:applications],
            &(&1 in [:kernel, :stdlib, :elixir, :crypto, :jason, :toml])
          ),
          "ConfigSpec has a business/runtime dependency"
        )

        IO.puts("PASS #{product}: #{Enum.map_join(Enum.sort(names), ", ", &Atom.to_string/1)}")

        contract_path
        |> Path.dirname()
        |> Path.join("*.beam")
        |> Path.wildcard()
        |> Map.new(&{Path.basename(&1), File.read!(&1)})
      end)

    [management_contract, worker_contract] = contracts

    require!(
      management_contract != %{} and management_contract == worker_contract,
      "products do not package the same ConfigSpec implementation"
    )

    IO.puts("ARCHITECTURE BOUNDARY PASSED: two isolated business releases, one pure ConfigSpec")
  end

  defp require!(condition, message) do
    if !condition, do: raise(message)
  end
end

[release_root] = System.argv()
YellowDog.ReleaseBoundary.check!(release_root)
