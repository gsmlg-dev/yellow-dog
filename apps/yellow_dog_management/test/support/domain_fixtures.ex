defmodule YellowDog.Management.DomainFixtures do
  def zone(name \\ "example.test.") do
    ns = "ns1." <> name

    %{
      "name" => name,
      "records" => [
        %{
          "name" => name,
          "type" => "SOA",
          "ttl" => 300,
          "data" => %{
            "mname" => ns,
            "rname" => "hostmaster." <> name,
            "serial" => 1,
            "refresh" => 3600,
            "retry" => 600,
            "expire" => 86_400,
            "minimum" => 300
          }
        },
        %{"name" => name, "type" => "NS", "ttl" => 300, "data" => %{"host" => ns}},
        %{"name" => ns, "type" => "A", "ttl" => 300, "data" => %{"address" => "192.0.2.10"}}
      ]
    }
  end

  def service(worker_id, revision, state \\ "running") do
    %{
      "worker_id" => worker_id,
      "id" => "dns",
      "type" => "dns",
      "desired_state" => state,
      "config" => %{"listen_address" => "127.0.0.1", "port" => 5300},
      "expected_revision" => revision
    }
  end
end
