defmodule Burrito.Steps.Patch.CopyERTSTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Burrito.Builder.Context
  alias Burrito.Builder.Target
  alias Burrito.Steps.Patch.CopyERTS

  # Each test builds its own ERTS and release trees under a unique temp dir.
  setup do
    tmp =
      Path.join(System.tmp_dir(), "copy_erts_test_#{System.unique_integer([:positive])}")
      |> Path.expand()

    :ok = File.mkdir_p(tmp)

    on_exit(fn -> {:ok, _} = File.rm_rf(tmp) end)

    {:ok, tmp: tmp}
  end

  describe "nif_libraries/1" do
    test "finds NIFs in a flat layout (no otp-*/ wrapper)", %{tmp: tmp} do
      erts = Path.join(tmp, "erts")
      write(erts, "erts-16.0/bin/beam.smp", "beam")
      crypto = write(erts, "lib/crypto-5.6/priv/lib/crypto.so", "crypto")
      asn1 = write(erts, "lib/asn1-5.3/priv/lib/asn1rt_nif.so", "asn1")

      assert {:ok, {root, paths}} = CopyERTS.nif_libraries(erts)
      assert root == erts
      assert Enum.sort(paths) == Enum.sort([crypto, asn1])
    end

    test "finds NIFs in a nested otp-*/ layout", %{tmp: tmp} do
      erts = Path.join(tmp, "erts")
      nested = Path.join(erts, "otp-28.0-linux-x86_64")
      write(nested, "erts-16.0/bin/beam.smp", "beam")
      crypto = write(nested, "lib/crypto-5.6/priv/lib/crypto.so", "crypto")
      asn1 = write(nested, "lib/asn1-5.3/priv/lib/asn1rt_nif.so", "asn1")

      assert {:ok, {root, paths}} = CopyERTS.nif_libraries(erts)
      assert root == nested
      assert Enum.sort(paths) == Enum.sort([crypto, asn1])
    end

    test "ignores a stray lib/ outside the ERTS root", %{tmp: tmp} do
      erts = Path.join(tmp, "erts")
      nested = Path.join(erts, "otp-28.0-linux-x86_64")
      write(nested, "erts-16.0/bin/beam.smp", "beam")
      crypto = write(nested, "lib/crypto-5.6/priv/lib/crypto.so", "crypto")
      write(erts, "lib/x/priv/lib/y.so", "stray")

      assert {:ok, {root, paths}} = CopyERTS.nif_libraries(erts)
      assert root == nested
      assert paths == [crypto]
    end

    test "returns an error when there is no erts-* dir", %{tmp: tmp} do
      erts = Path.join(tmp, "erts")
      write(erts, "lib/crypto-5.6/priv/lib/crypto.so", "crypto")

      assert {:error, :erts_not_found} = CopyERTS.nif_libraries(erts)
    end

    test "finds .dll and .exe artifacts in a flat layout", %{tmp: tmp} do
      erts = Path.join(tmp, "erts")
      write(erts, "erts-16.0/bin/beam.smp", "beam")
      dll = write(erts, "lib/crypto-5.6/priv/lib/crypto.dll", "crypto")
      exe = write(erts, "lib/os_mon-2.9/priv/bin/win32sysinfo.exe", "exe")

      assert {:ok, {_root, paths}} = CopyERTS.nif_libraries(erts)
      assert Enum.sort(paths) == Enum.sort([dll, exe])
    end

    test "finds .dll and .exe artifacts in a nested layout", %{tmp: tmp} do
      erts = Path.join(tmp, "erts")
      nested = Path.join(erts, "otp-28.0-windows-x86_64")
      write(nested, "erts-16.0/bin/beam.smp", "beam")
      dll = write(nested, "lib/crypto-5.6/priv/lib/crypto.dll", "crypto")
      exe = write(nested, "lib/os_mon-2.9/priv/bin/win32sysinfo.exe", "exe")

      assert {:ok, {_root, paths}} = CopyERTS.nif_libraries(erts)
      assert Enum.sort(paths) == Enum.sort([dll, exe])
    end
  end

  describe "execute/1" do
    test "warns when the custom ERTS provides no NIF libraries", %{tmp: tmp} do
      erts = Path.join(tmp, "erts")
      write(erts, "erts-16.0/bin/beam.smp", "beam")
      write(erts, "lib/stdlib-7.0/ebin/lists.beam", "beam")
      work = host_release(tmp)

      {_context, stderr} = run_execute(erts, work, tmp)

      assert stderr =~ "provided no NIF libraries"
      assert {:ok, {_root, []}} = CopyERTS.nif_libraries(erts)
    end

    test "removes a host NIF whose extension differs from the replacement", %{tmp: tmp} do
      erts = Path.join(tmp, "erts")
      nested = Path.join(erts, "otp-x")
      write(nested, "erts-16.0/bin/beam.smp", "beam")
      write(nested, "lib/a-1/priv/lib/a.so", "a-so")
      # Sorts last, so a buggy extension lookup over the whole list sees ".dll".
      write(nested, "lib/b-1/priv/lib/b.dll", "b-dll")
      work = host_release(tmp)
      write(work, "lib/a-1/priv/lib/a.dll", "host-a-dll")

      run_execute(erts, work, tmp)

      refute File.exists?(Path.join(work, "lib/a-1/priv/lib/a.dll"))
      assert File.exists?(Path.join(work, "lib/a-1/priv/lib/a.so"))
    end

    test "replaces NIFs and ERTS bins from a flat layout", %{tmp: tmp} do
      erts = Path.join(tmp, "erts")
      write(erts, "erts-16.0/bin/beam.smp", "custom-beam")
      # Launcher script at the flat root; must not be copied into erts-*/bin.
      write(erts, "bin/erl", "decoy-erl")
      write(erts, "lib/crypto-5.6/priv/lib/crypto.so", "custom-crypto")
      work = host_release(tmp)
      write(work, "lib/crypto-5.6/priv/lib/crypto.so", "host-crypto")

      run_execute(erts, work, tmp)

      assert {:ok, "custom-crypto"} =
               File.read(Path.join(work, "lib/crypto-5.6/priv/lib/crypto.so"))

      assert {:ok, "custom-beam"} = File.read(Path.join(work, "erts-15.0/bin/beam.smp"))
      refute File.exists?(Path.join(work, "erts-15.0/bin/erl"))
    end

    test "raises before touching the release when there is no erts-* dir", %{tmp: tmp} do
      erts = Path.join(tmp, "erts")
      write(erts, "not_an_erts/lib/crypto-5.6/priv/lib/crypto.so", "crypto")
      work = host_release(tmp)

      error =
        assert_raise RuntimeError, fn ->
          capture_io(:stderr, fn ->
            capture_io(fn -> CopyERTS.execute(context(erts, work, tmp)) end)
          end)
        end

      assert error.message =~ erts
      assert error.message =~ "otp-"
      assert error.message =~ "not_an_erts"
      assert {:ok, "host-beam"} = File.read(Path.join(work, "erts-15.0/bin/beam.smp"))
    end
  end

  defp write(base, relative, content) do
    path = Path.join(base, relative)
    :ok = File.mkdir_p(Path.dirname(path))
    :ok = File.write(path, content)
    path
  end

  # A minimal host release: erts-*/bin with a binary, plus lib/.
  defp host_release(tmp) do
    work = Path.join(tmp, "work")
    write(work, "erts-15.0/bin/beam.smp", "host-beam")
    :ok = File.mkdir_p(Path.join(work, "lib"))
    work
  end

  defp context(erts, work, tmp) do
    %Context{
      target: %Target{
        alias: :test,
        cpu: :aarch64,
        os: :darwin,
        cross_build: false,
        qualifiers: [],
        erts_source: {:local_unpacked, path: erts},
        debug?: false
      },
      mix_release: nil,
      work_dir: work,
      self_dir: tmp,
      extra_build_env: [],
      halted: false
    }
  end

  # Log.info writes to stdout and Log.warning/success to stderr; capture both.
  defp run_execute(erts, work, tmp) do
    with_io(:stderr, fn ->
      {context, _stdout} = with_io(fn -> CopyERTS.execute(context(erts, work, tmp)) end)
      context
    end)
  end
end
