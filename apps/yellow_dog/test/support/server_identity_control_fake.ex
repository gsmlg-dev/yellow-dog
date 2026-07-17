defmodule YellowDog.ServerIdentityControlFake do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          responses: %{
            control_list_hosts: {:ok, []},
            control_list_audit: {:ok, []},
            control_host: {:error, :not_found},
            control_approve_host: {:error, :not_found},
            control_revoke_host: {:error, :not_found},
            control_delete_host: {:error, :not_found},
            clock: ~U[2026-07-17 00:00:00Z]
          },
          calls: []
        }
      end,
      name: __MODULE__
    )
  end

  def configure(responses) when is_map(responses) do
    Agent.update(__MODULE__, fn state ->
      %{state | responses: Map.merge(state.responses, responses)}
    end)
  end

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def call(function, arguments) do
    response =
      Agent.get_and_update(__MODULE__, fn state ->
        value = Map.get(state.responses, function, {:error, :apply_failed})
        {value, %{state | calls: [{function, arguments} | state.calls]}}
      end)

    run(response)
  end

  defp run({:raise, reason}), do: raise(reason)
  defp run({:exit, reason}), do: exit(reason)
  defp run({:throw, reason}), do: throw(reason)
  defp run(value), do: value
end

defmodule YellowDog.ServerIdentityControlFake.Owner do
  @moduledoc false

  def control_list_hosts,
    do: YellowDog.ServerIdentityControlFake.call(:control_list_hosts, [])

  def control_list_approvals,
    do: YellowDog.ServerIdentityControlFake.call(:control_list_approvals, [])

  def control_list_tokens,
    do: YellowDog.ServerIdentityControlFake.call(:control_list_tokens, [])

  def control_list_policies,
    do: YellowDog.ServerIdentityControlFake.call(:control_list_policies, [])

  def control_list_audit,
    do: YellowDog.ServerIdentityControlFake.call(:control_list_audit, [])

  def control_host(host_id),
    do: YellowDog.ServerIdentityControlFake.call(:control_host, [host_id])

  def control_token(token_id),
    do: YellowDog.ServerIdentityControlFake.call(:control_token, [token_id])

  def control_approve_host(host_id),
    do: YellowDog.ServerIdentityControlFake.call(:control_approve_host, [host_id])

  def control_revoke_host(host_id),
    do: YellowDog.ServerIdentityControlFake.call(:control_revoke_host, [host_id])

  def control_delete_host(host_id),
    do: YellowDog.ServerIdentityControlFake.call(:control_delete_host, [host_id])

  def control_create_token(payload),
    do: YellowDog.ServerIdentityControlFake.call(:control_create_token, [payload])

  def control_revoke_token(token_id),
    do: YellowDog.ServerIdentityControlFake.call(:control_revoke_token, [token_id])

  def control_update_policies(policies),
    do: YellowDog.ServerIdentityControlFake.call(:control_update_policies, [policies])
end

defmodule YellowDog.ServerIdentityControlFake.Clock do
  @moduledoc false

  def utc_now, do: YellowDog.ServerIdentityControlFake.call(:clock, [])
end

defmodule YellowDog.ServerIdentityControlFake.InternalUndefinedFunctionOwner do
  @moduledoc false

  def control_list_hosts do
    apply(__MODULE__, :missing_internal_function, [])
  end
end
