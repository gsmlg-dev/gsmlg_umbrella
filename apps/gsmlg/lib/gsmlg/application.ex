defmodule GSMLG.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do

    {:ok, whisper} = Bumblebee.load_model({:hf, "openai/whisper-tiny"})
    {:ok, featurizer} = Bumblebee.load_featurizer({:hf, "openai/whisper-tiny"})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "openai/whisper-tiny"})
    {:ok, generation_config} = Bumblebee.load_generation_config({:hf, "openai/whisper-tiny"})

    serving =
      Bumblebee.Audio.speech_to_text_whisper(whisper, featurizer, tokenizer, generation_config,
        defn_options: [compiler: EXLA]
      )

    children = [
      {Nx.Serving, name: WhisperServing, serving: serving},
      {GSMLG.SimpleCache, []},
      {Cachex, name: :aws_cache},
      {Phoenix.SessionProcess.Supervisor, name: GSMLG.SessionProcess},
      # Start the Ecto repository
      GSMLG.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: GSMLG.PubSub, adapter: Phoenix.PubSub.PG2},
      {GSMLG.CommandPlatform.Supervisor, name: GSMLG.CommandPlatform.Supervisor},
      # Start distribute Node
      {Finch, name: GSMLG.Finch},
      GSMLG.WebPush.Subscriptions,
      {GSMLG.Node.Supervisor, name: GSMLG.Node.Supervisor},
      {GSMLG.Chess.Supervisor, name: GSMLG.Chess.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.Supervisor)
  end
end
