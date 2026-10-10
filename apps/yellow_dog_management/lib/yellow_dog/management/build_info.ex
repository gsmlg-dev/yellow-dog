defmodule YellowDog.Management.BuildInfo do
  @moduledoc "Build metadata embedded in Management, including source-less releases."

  @root Path.expand("../../../../..", __DIR__)
  @version_file Path.join(@root, "mix.exs")
  @external_resource @version_file
  @environment to_string(Mix.env())
  @env_keys ~w(RELEASE_VERSION YELLOW_DOG_BUILD_GIT_REF YELLOW_DOG_BUILD_GIT_COMMIT YELLOW_DOG_RELEASE_TIME)
  @build_env Map.new(@env_keys, &{&1, System.get_env(&1)})
  @build_values Map.new(@build_env, fn {key, value} ->
                  {key, if(value in [nil, ""], do: nil, else: value)}
                end)

  git = fn args ->
    case System.find_executable("git") do
      nil ->
        "Unavailable"

      executable ->
        case System.cmd(executable, ["-C", @root | args], stderr_to_stdout: true) do
          {output, 0} -> String.trim(output)
          _ -> "Unavailable"
        end
    end
  end

  @source_commit git.(["rev-parse", "HEAD"])
  @source_ref git.(["symbolic-ref", "--short", "HEAD"])
  @version @build_values["RELEASE_VERSION"] ||
             hd(
               Regex.run(~r/version: "([^"]+)"/, File.read!(@version_file),
                 capture: :all_but_first
               )
             )
  @info %{
    version: @version,
    display_version: "v#{@version}" <> if(@environment == "dev", do: "-dev", else: ""),
    environment: @environment,
    git_ref:
      @build_values["YELLOW_DOG_BUILD_GIT_REF"] ||
        if(@source_ref == "Unavailable", do: @source_commit, else: @source_ref),
    git_commit: @build_values["YELLOW_DOG_BUILD_GIT_COMMIT"] || @source_commit,
    release_time: @build_values["YELLOW_DOG_RELEASE_TIME"] || "Unavailable",
    built_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  }

  def info, do: @info

  # Cached builds must refresh provenance after a checkout or release metadata change.
  def __mix_recompile__? do
    @build_env != Map.new(@env_keys, &{&1, System.get_env(&1)}) or
      @source_commit != git(["rev-parse", "HEAD"]) or
      @source_ref != git(["symbolic-ref", "--short", "HEAD"])
  end

  defp git(args) do
    case System.find_executable("git") do
      nil ->
        "Unavailable"

      executable ->
        case System.cmd(executable, ["-C", @root | args], stderr_to_stdout: true) do
          {output, 0} -> String.trim(output)
          _ -> "Unavailable"
        end
    end
  end
end
