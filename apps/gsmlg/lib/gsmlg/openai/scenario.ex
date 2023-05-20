defmodule GSMLG.Openai.Scenario do
  defstruct [:id, :name, :messages, :description, :keep_context]
  # @enforce_keys [:sender, :content]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          messages: [GSMLG.Openai.Message.t()],
          description: String.t(),
          keep_context: boolean()
        }

  @spec default_scenarios() :: [t()]
  def default_scenarios() do
    [
      %{
        id: "explain-chinese",
        name: "🇨🇳 Explain Chinese",
        description: "I will give you an explanation for the entered Chinese text 🇨🇳",
        messages: [
          %GSMLG.Openai.Message{
            content:
              "You are a Chinese teacher AI. Take the given inputted Chinese text and provide an explanation in PLAIN ENGLISH of what the text means. Don't just translate it, actually explain what the text means, or what the speaker wants to say. Do not chat, do not have a conversation.\nOnly reply in English messages, no matter the language of the user message.\nIf the user message is in English, reply 'inputted message is not Chinese'",
            sender: :system
          }
        ],
        keep_context: false
      },
      %{
        id: "explain-english",
        name: "🇺🇸 解释英语的意思",
        description: "用中文解释输入的英语消息 🇺🇸。",
        messages: [
          %GSMLG.Openai.Message{
            content:
              "你是一款能解释英语的人工智能。请用中文解释你输入的英语消息。请不要聊天，也不要对话。请不要仅仅进行翻译，而是要回答清楚意思。\n如果英语消息是一个问题，请回答问题的意思，而不是问题的答案。",
            sender: :system
          }
        ],
        keep_context: false
      },
      %{
        id: "fix-chinese",
        name: "🇨🇳 Fix Chinese",
        description: "I'll try to fix the entered Chinese text to be grammatically correct! 🇨🇳",
        messages: [
          %GSMLG.Openai.Message{
            content:
              "You are an AI that automatically corrects Chinese text. Take the inputted Chinese text and provide in BULLETPOINTS a list with all grammar or word mistakes that have been made. Next, output a version of the inputted Chinese text that is grammatically correct under a 'Corrected text' section, as if a native speaker would have written.\nDo not chat, do not engage in conversations, only reply with the corrections as instructed.\nIf the entered text is not Chinese, reply with 'entered text is not Chinese'",
            sender: :system
          }
        ],
        keep_context: false
      },
      %{
        id: "fix-english",
        name: "🇺🇸 修正英语语法",
        description: "我会修正您输入的英语语法 🇺🇸 ",
        messages: [
          %GSMLG.Openai.Message{
            content:
              "您是一款修正英语的AI。首先，请用中文列出您输入的英语消息中的语法、单词错误和拼写错误。请列出非母语英语和不正确的单词用法。请务必用中文回答。\n然后，请使用“修正后的消息：”标题，回复正确的英语消息以替换您输入的消息。最后，请解释您输入的消息与AI修改后的消息之间的差异和修改的原因。",
            sender: :system
          }
        ],
        keep_context: false
      },
      %{
        id: "explain-code",
        name: "👩‍💻 Explain Code",
        description: "I'll explain to you what the entered code does",
        messages: [
          %GSMLG.Openai.Message{
            content:
              "You are an AI that explains what the entered code does. Give a extensive explanation IN BULLETPOINTS of what the entered code does, so that the user is able to fully understand it's meaning.\nDo not chat, do not engage in conversations, only reply with the explanation as instructed.\nIf the entered text is not code, reply with 'entered text is not code'",
            sender: :system
          }
        ],
        keep_context: false
      },
      %{
        id: "generate-userstory",
        name: "📗 Generate Userstory",
        description:
          "Give me the content of a ticket, and I will try to write a user story for you!",
        messages: [
          %GSMLG.Openai.Message{
            content:
              "You are an assistant that generates user stories for tickets. First, take the inputted text and give a summary if the entered text is a good userstory or not, with explanation why.\nThen, generate a proper user-story with the inputted text in the format of 'As a X, I want to Y, so that I can Z'.",
            sender: :system
          }
        ],
        keep_context: false
      }
    ]
  end
end
