defmodule Burrito.Steps.Patch.CopyERTS do
  @moduledoc """
  This step copies the new ERTS bins into the release, as well as replaces built-in NIFs.
  """
  alias Burrito.Builder.Context
  alias Burrito.Builder.Log
  alias Burrito.Builder.Step

  @behaviour Step

  @impl Step
  def execute(%Context{} = context) do
    case context.target.erts_source do
      # nothing to do
      {:runtime, _} ->
        context

      {:local_unpacked, [path: location]} ->
        # copy unpacked bins into release working directory
        do_copy(location, context)
    end

    context
  end

  @doc """
  Locates the ERTS root (the parent of the `erts-*` dir) inside `erts_location`
  and lists the NIF libraries and executables under its `lib/`.

  Works for both the flat layout (`erts-*/`, `lib/`, ... at the top level) and
  the `otp-*/` wrapped layout.
  """
  @spec nif_libraries(Path.t()) :: {:ok, {Path.t(), [Path.t()]}} | {:error, :erts_not_found}
  def nif_libraries(erts_location) do
    case find_erts_dir(erts_location) do
      nil ->
        {:error, :erts_not_found}

      erts_dir ->
        root = Path.dirname(erts_dir)
        paths = Path.join([root, "lib", "**/*.{so,dll,exe}"]) |> Path.wildcard()
        {:ok, {root, paths}}
    end
  end

  defp do_copy(erts_location, %Context{} = context) do
    Log.info(:step, "Replacing ERTS binaries...")

    # Discover the custom ERTS before touching the release
    {erts_root, to_copy} =
      case nif_libraries(erts_location) do
        {:ok, found} -> found
        {:error, :erts_not_found} -> raise erts_not_found_message(erts_location)
      end

    unpacked_path = find_erts_dir(erts_location)

    # Clean out current bins
    dest_bin_path =
      Path.join(context.work_dir, ["erts-*/", "bin/"])
      |> Path.expand()
      |> Path.wildcard()
      |> List.first()

    File.rm_rf!(dest_bin_path)
    File.mkdir!(dest_bin_path)

    # Copy in new bins from unpacked ERTS
    src_bin_path = Path.join(unpacked_path, ["bin/"])

    File.cp_r!(src_bin_path, dest_bin_path)

    # The ERTS comes with some pre-built NIFs, so we need to replace those

    src_lib_path = Path.join(erts_root, "lib")

    dest_lib_path = Path.join(context.work_dir, ["lib/"]) |> Path.expand()

    # The DLL/SO files in to_copy come from our replacement ERTS
    # The new ERTS is treated as the "authoritative" ERTS, some DLLs/SOs may exist in it
    # That do not exist in the host/source ERTS. We'll log when we replace a library file
    if to_copy == [] do
      Log.warning(
        :step,
        "Custom ERTS at #{erts_location} provided no NIF libraries; the release keeps the host's NIFs"
      )
    end

    Enum.each(to_copy, fn file_to_copy ->
      destination_file_path =
        Path.join(dest_lib_path, Path.relative_to(file_to_copy, src_lib_path))

      possible_file_to_replace =
        String.replace_suffix(destination_file_path, Path.extname(file_to_copy), "*.{so,dll}")
        |> Path.wildcard()
        |> List.first()

      full_directory = Path.dirname(destination_file_path)
      File.mkdir_p!(full_directory)

      if possible_file_to_replace != nil do
        File.rm!(possible_file_to_replace)

        Log.warning(
          :step,
          "Overwriting NIF library #{possible_file_to_replace} with #{file_to_copy}"
        )
      end

      File.copy!(file_to_copy, destination_file_path)

      Log.success(
        :step,
        "Installed NIF library #{destination_file_path}"
      )
    end)
  end

  defp find_erts_dir(erts_location) do
    recursively_find_dir([erts_location], ~r/^erts-.*$/)
  end

  defp erts_not_found_message(erts_location) do
    entries =
      case File.ls(erts_location) do
        {:ok, names} -> names |> Enum.sort() |> Enum.join(", ")
        {:error, reason} -> "unreadable (#{inspect(reason)})"
      end

    """
    No erts-* directory found in custom ERTS at #{erts_location}.
    Supported layouts: flat (erts-*/, lib/, ... at the top level) or wrapped (otp-*/erts-*/, otp-*/lib/, ...).
    Top-level entries: #{entries}\
    """
  end

  defp recursively_find_dir([], _target_dir_pattern), do: nil

  defp recursively_find_dir([current_path | rest], target_dir_pattern) do
    case String.match?(Path.basename(current_path), target_dir_pattern) do
      true ->
        Path.expand(current_path)

      false ->
        dir_paths =
          for file_name <- File.ls!(current_path),
              File.dir?(Path.join(current_path, file_name)),
              not String.starts_with?(file_name, ".") do
            Path.join(current_path, file_name)
          end

        recursively_find_dir(rest ++ dir_paths, target_dir_pattern)
    end
  end
end
