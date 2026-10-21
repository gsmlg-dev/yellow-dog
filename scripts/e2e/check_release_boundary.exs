defmodule YellowDog.ReleaseBoundary do
  @optional_native_apps [:abyss_raw, :abyss_dhcp_socket, :rustler]
  @retired_http_apps [:bandit, :thousand_island]
  @http_apps [:gaoxy_http, :gaoxy, :hell, :websock_adapter, :websock, :plug, :hpax]
  @http_server_apps @http_apps -- [:hpax]

  def check!(root) do
    products = [:yellow_dog_management, :yellow_dog_worker]
    expected_apps = products ++ [:yellow_dog_config_spec, :ex_dns]
    config = Mix.Project.config()

    lock = Mix.Dep.Lock.read()

    abyss_version =
      case lock[:abyss] do
        {:hex, :abyss, version, _, _, _, "hexpm", _} -> version
        _ -> raise "Abyss must be locked to a Hex dependency"
      end

    active_dependencies = Mix.Dep.load_and_cache()

    require!(
      Enum.all?(active_dependencies, &(&1.app not in @optional_native_apps)),
      "default products: optional native dependency in active graph"
    )

    require!(
      Enum.all?(active_dependencies, &(&1.app not in @retired_http_apps)),
      "default products: retired HTTP dependency in active graph"
    )

    require!(
      Enum.sort(Map.keys(Mix.Project.apps_paths())) == Enum.sort(expected_apps),
      "unsupported umbrella applications"
    )

    require!(
      Enum.sort(Keyword.keys(config[:releases])) == Enum.sort(products),
      "supported business releases must be exactly Management and Worker"
    )

    gaoxy_version = hex_version!(lock, :gaoxy_http, :gaoxy_http)

    require!(
      hex_version!(lock, :gaoxy, :gaoxy) == gaoxy_version and
        hex_version!(lock, :websock_adapter, :gaoxy_websock_adapter) == gaoxy_version,
      "Gaoxy HTTP and WebSock cohort versions differ"
    )

    websocket = Enum.find(active_dependencies, &(&1.app == :websock_adapter))

    require!(
      websocket != nil and websocket.opts[:override] == true and
        to_string(websocket.opts[:hex]) == "gaoxy_websock_adapter",
      "Gaoxy WebSock Hex override is missing"
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
            [:ex_dns, :ex_dhcp, :concord, :mnesia, :gaoxy_http3, :gaoxy_proxy]
          else
            [
              :ecto,
              :ecto_sql,
              :postgrex,
              :db_connection,
              :phoenix,
              :phoenix_live_view,
              :plug,
              :concord,
              :mnesia
            ] ++ @http_server_apps ++ [:gaoxy_http3, :gaoxy_proxy]
          end

        require!(Enum.all?(names, &(&1 not in forbidden)), "#{product}: forbidden dependency")

        require!(
          Enum.all?(names, &(&1 not in @retired_http_apps)),
          "#{product}: retired HTTP dependency is packaged"
        )

        require!(
          Enum.all?(names, &(&1 not in @optional_native_apps)),
          "#{product}: optional native dependency is packaged"
        )

        native_artifacts =
          directory
          |> Path.join("lib/**/priv/**/*dhcp_socket*")
          |> Path.wildcard()
          |> Enum.filter(&(Path.extname(&1) in [".so", ".dylib", ".dll"]))

        require!(native_artifacts == [], "#{product}: optional native artifact is packaged")

        {_, product_specification} = Map.fetch!(specifications, product)

        require!(:abyss in names, "#{product}: Abyss runtime dependency is missing")

        {_, abyss_specification} = Map.fetch!(specifications, :abyss)

        require!(
          to_string(abyss_specification[:vsn]) == abyss_version,
          "#{product}: packaged Abyss does not match the Hex lock"
        )

        if product == :yellow_dog_management do
          require!(
            :gaoxy_http in product_specification[:applications] and
              Enum.all?(@http_apps, &(&1 in names)),
            "#{product}: Gaoxy HTTP runtime dependency is missing"
          )

          for app <- [:gaoxy_http, :gaoxy, :websock_adapter] do
            {_, specification} = Map.fetch!(specifications, app)

            require!(
              to_string(specification[:vsn]) == gaoxy_version,
              "#{product}: packaged Gaoxy HTTP cohort does not match the Hex lock"
            )
          end

          {_, gaoxy} = Map.fetch!(specifications, :gaoxy)
          {_, http} = Map.fetch!(specifications, :gaoxy_http)

          require!(
            Enum.all?([:abyss, :hell], &(&1 in gaoxy[:applications])) and
              Enum.all?([:gaoxy, :websock_adapter], &(&1 in http[:applications])),
            "#{product}: Gaoxy HTTP runtime links are missing"
          )
        else
          require!(
            :abyss in product_specification[:applications],
            "#{product}: Abyss runtime dependency is missing"
          )
        end

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
          "Elixir.AbyssDhcpSocket.Native" not in packaged_modules,
          "#{product}: optional native implementation is packaged"
        )

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

  defp hex_version!(lock, app, package) do
    case lock[app] do
      {:hex, ^package, version, _, _, _, "hexpm", _} -> version
      _ -> raise "#{app} must be locked to Hex package #{package}"
    end
  end

  defp require!(condition, message) do
    if !condition, do: raise(message)
  end
end

[release_root] = System.argv()
YellowDog.ReleaseBoundary.check!(release_root)
