defmodule Skir.MixProject do
  use Mix.Project

  def project do
    [
      app: :skir_elixir_client,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:jason, "~> 1.4"},
        {:plug, ">= 1.16.0 and < 2.0.0", only: :test},
        {:ex_doc, "~> 0.40.4", only: :dev, runtime: false}
      ],
      description: "Native Elixir runtime and SkirRPC implementation for Skir schemas",
      name: "skir_elixir_client",
      source_url: "https://github.com/mishmish-dev/skir-elixir-client",
      homepage_url: "https://hexdocs.pm/skir_elixir_client",
      docs: &docs/0,
      package: [
        links: %{
          "GitHub" => "https://github.com/mishmish-dev/skir-elixir-client",
          "Documentation" => "https://hexdocs.pm/skir_elixir_client"
        },
        licenses: ["MIT"],
        files: ["lib", "mix.exs", "README.md", "README.dev.md", "docs", "LICENSE"]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl]]

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "README.dev.md",
        "docs/SKIRRPC.md",
        "docs/RELEASING.md",
        "docs/SKIRRPC_PARITY.md"
      ],
      source_ref: "v#{project()[:version]}",
      canonical: "https://hexdocs.pm/skir_elixir_client"
    ]
  end
end
