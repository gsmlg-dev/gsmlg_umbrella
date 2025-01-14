defmodule GSMLGAdminWeb.GhatgptLive.Index do
  require Logger

  alias GSMLG.Openai.Message
  alias GSMLGAdminWeb.Chatgpt.LoadingIndicatorComponent
  alias GSMLGAdminWeb.Chatgpt.AlertComponent
  use GSMLGAdminWeb, :live_view
  use Phoenix.LiveView, layout: false

  use GSMLGOpenAI.StreamingClient

  @type state :: %{messages: [Message.t()], loading: boolean(), streaming_message: Message.t()}

  @spec dummy_messages() :: [Message.t()]
  defp dummy_messages,
    do: [
      %Message{content: "Hi there! How can I assist you today?", sender: :assistant, id: 0}
    ]

  @spec initial_state() :: state
  defp initial_state,
    do: %{
      page_title: "ChatGPT",
      messages: dummy_messages(),
      loading: false,
      streaming_message: %Message{content: "", sender: :assistant, id: -1}
    }

  def mount(
        _params,
        %{
          "model" => model,
          "models" => models,
          "mode" => :scenario,
          "scenario" => scenario
        } = session,
        socket
      ) do
    {:ok, pid} =
      GSMLG.Openai.Chatgpt.start_link(%{
        messages: scenario.messages,
        keep_context: Map.get(scenario, "keep_context", false)
      })

    {:ok,
     socket
     |> assign(initial_state())
     |> assign(%{
       openai_pid: pid,
       model: model,
       models: models,
       scenarios: Map.get(session, "scenarios"),
       scenario: scenario,
       mode: :scenario,
       messages: [
         %GSMLG.Openai.Message{content: scenario.description, sender: :assistant, id: 0}
       ]
     })}
  end

  def mount(_params, %{"model" => model, "models" => models} = session, socket) do
    {:ok, pid} = GSMLG.Openai.Chatgpt.start_link(%{})

    {:ok,
     socket
     |> assign(%{
       openai_pid: pid,
       model: model,
       models: models,
       scenarios: Map.get(session, "scenarios"),
       mode: :chat
     })
     |> assign(initial_state())}
  end

  def handle_event(ev, params, socket) do
    Logger.info("Unhandled event at live_view #{__MODULE__}",
      event: ev,
      params: params,
      socket: socket
    )
  end

  # -- sse client

  @spec parse_choices(any) :: String.t()
  defp parse_choices(%{text: content}) do
    content
  end

  defp parse_choices(%{delta: %{content: content}}) do
    content
  end

  defp parse_choices(choices) when is_list(choices) do
    List.first(choices)
    |> parse_choices()
  end

  defp parse_choices(_) do
    ""
  end

  def handle_data(%{id: _id, choices: choices}, state) do
    streamed_text = parse_choices(choices)

    streaming_message =
      state.assigns.streaming_message
      |> Map.put(:content, state.assigns.streaming_message.content <> streamed_text)

    {:noreply,
     state
     |> assign(streaming_message: streaming_message)}
  end

  def handle_error(e, state) do
    Logger.error("Error occurred in live_view #{__MODULE__}", error: error)
    Process.send(self(), {:set_error, "#{inspect(e)}"}, [])
    Process.send(self(), :stop_loading, [])

    {:noreply, state}
  end

  def handle_finish(state) do
    # swap streaming message into a real message
    Process.send(
      self(),
      {:commit_streaming_message, state.assigns.streaming_message},
      []
    )

    {:noreply, state}
  end

  # -- sse client

  def handle_info({:set_error, msg}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, msg)
     |> push_event("newmessage", %{})}
  end

  def handle_info(:unset_error, socket) do
    {:noreply,
     socket
     |> clear_flash(:error)
     |> push_event("newmessage", %{})}
  end

  def handle_info({:add_message, msg}, socket) do
    new_id = Enum.count(socket.assigns.messages) + 1
    msg = Map.put(msg, :id, new_id)

    {:noreply,
     socket
     |> assign(%{messages: socket.assigns.messages ++ [msg]})
     |> push_event("newmessage", %{})}
  end

  def handle_info({:commit_streaming_message, msg}, socket) do
    new_id = Enum.count(socket.assigns.messages) + 1
    msg = Map.put(msg, :id, new_id)

    # insert into stateful openai container so we have history
    GSMLG.Openai.Chatgpt.insert_message(socket.assigns.openai_pid, msg)

    Process.send(self(), :stop_loading, [])

    {:noreply,
     socket
     |> assign(%{
       messages: socket.assigns.messages ++ [msg],
       streaming_message: %Message{content: "", sender: :assistant, id: -1}
     })
     |> push_event("newmessage", %{})}
  end

  def handle_info({:update_messages, msgs}, socket) do
    {:noreply, assign(socket, %{messages: msgs})}
  end

  def handle_info(:stop_loading, socket) do
    {:noreply, assign(socket, %{loading: false})}
  end

  def handle_info({:msg_submit, text}, socket) do
    self = self()

    model = Map.get(socket.assigns, :model)

    Process.send(
      self,
      {:add_message, %Message{content: text, sender: :user, id: 0}},
      []
    )

    spawn(fn ->
      case GSMLG.Openai.Chatgpt.send(socket.assigns.openai_pid, text, model, self) do
        {:ok, result} when is_reference(result) ->
          nil

        {:ok, result} ->
          Process.send(self, {:add_message, result}, [])
          Process.send(self, :stop_loading, [])

        {:error, e} ->
          Process.send(self, {:set_error, "#{inspect(e)}"}, [])
          Process.send(self, :stop_loading, [])
      end
    end)

    {:noreply, socket |> assign(:loading, true) |> clear_flash()}
  end
end
