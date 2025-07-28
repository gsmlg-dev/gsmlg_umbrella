defmodule GSMLG.Nx do
  @moduledoc """
  Documentation for `GSMLG.Nx`.
  """
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  @impl true
  def init(_) do
    children = [
      {Nx.Serving, name: WhisperServing, serving: whisper_serving()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def whisper_serving() do
    {:ok, whisper} = Bumblebee.load_model({:hf, "openai/whisper-tiny"})
    {:ok, featurizer} = Bumblebee.load_featurizer({:hf, "openai/whisper-tiny"})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "openai/whisper-tiny"})
    {:ok, generation_config} = Bumblebee.load_generation_config({:hf, "openai/whisper-tiny"})

    serving =
      Bumblebee.Audio.speech_to_text_whisper(whisper, featurizer, tokenizer, generation_config,
        defn_options: [compiler: EXLA]
      )

    serving
  end
end
