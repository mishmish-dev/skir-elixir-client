# Validate the actual Hex archive without requiring a published package.
root = File.cwd!()
artifacts = Path.join(root, ".artifacts/packages")
File.mkdir_p!(artifacts)

run = fn args, cwd ->
  {output, status} =
    System.cmd("mix", args, cd: cwd, env: [{"MIX_ENV", "prod"}], stderr_to_stdout: true)

  IO.write(output)
  if status != 0, do: raise("mix #{Enum.join(args, " ")} exited #{status}")
end

run.(["deps.get", "--check-locked"], root)
run.(["compile", "--warnings-as-errors"], root)
tarball = Path.join(artifacts, "skir_elixir_client.tar")
run.(["hex.build", "--output", tarball], root)

consumer =
  Path.join(System.tmp_dir!(), "skir-client-consumer-#{System.unique_integer([:positive])}")

vendor = Path.join(consumer, "vendor/skir")
File.mkdir_p!(vendor)

try do
  :ok = :erl_tar.extract(String.to_charlist(tarball), [{:cwd, String.to_charlist(vendor)}])

  :ok =
    :erl_tar.extract(String.to_charlist(Path.join(vendor, "contents.tar.gz")), [
      :compressed,
      {:cwd, String.to_charlist(vendor)}
    ])

  File.write!(Path.join(consumer, "mix.exs"), """
  defmodule Consumer.MixProject do
    use Mix.Project
    def project, do: [app: :consumer, version: "0.0.0", deps: [{:skir_elixir_client, path: "vendor/skir"}]]
    def application, do: [extra_applications: [:logger]]
  end
  """)

  File.cp!(Path.join(root, "mix.lock"), Path.join(consumer, "mix.lock"))
  run.(["deps.get", "--check-locked"], consumer)
  run.(["compile", "--warnings-as-errors"], consumer)

  run.(
    [
      "run",
      "-e",
      ~S"""
      for {type, value} <- [{:string, "packed ☃"}, {:int64, 9_223_372_036_854_775_807}, {{:array, :int32}, [1, -2, 3]}] do
        ^value = Skir.decode!(type, Skir.encode!(type, value))
        ^value = Skir.decode_json!(type, Skir.encode_json!(type, value))
      end
      :skir_elixir_client = Application.get_application(Skir)
      """
    ],
    consumer
  )

  IO.puts("PASS: installed Hex archive with only production dependencies and native round-trips.")
after
  File.rm_rf!(consumer)
end
