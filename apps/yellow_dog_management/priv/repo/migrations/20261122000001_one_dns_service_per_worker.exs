defmodule YellowDog.Management.Repo.Migrations.OneDNSServicePerWorker do
  use Ecto.Migration

  def change do
    create unique_index(:management_services, [:worker_id],
             name: :management_services_one_dns_per_worker,
             where: "type = 'dns'"
           )
  end
end
