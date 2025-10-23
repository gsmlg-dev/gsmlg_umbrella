defmodule GSMLG.Web.Components.ThemeSwitcher do
  @moduledoc """
  Phoenix 1.8 DaisyUI Theme Switcher Component.

  Provides a dropdown to switch between different DaisyUI themes.
  """

  use Phoenix.Component

  def theme_switcher(assigns) do
    assigns = assign(assigns, :themes, available_themes())

    ~H"""
    <div class="theme-switcher dropdown dropdown-top dropdown-end">
      <label tabindex="0" class="btn btn-circle btn-ghost btn-sm">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
          class="w-5 h-5 stroke-current"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M7 21a4 4 0 01-4-4V5a2 2 0 012-2h4a2 2 0 012 2v12a4 4 0 01-4 4zM21 5a2 2 0 00-2-2h-4a2 2 0 00-2 2v6a2 2 0 002 2h4a2 2 0 002-2V5z"
          >
          </path>
        </svg>
      </label>
      <ul
        tabindex="0"
        class="dropdown-content menu p-2 shadow bg-base-100 rounded-box w-52 max-h-80 overflow-y-auto"
      >
        <li class="menu-title">
          <span>Choose Theme</span>
        </li>
        <%= for theme <- @themes do %>
          <li>
            <a href="#" phx-click="set_theme" phx-value-theme={theme} class={theme_item_class(theme)}>
              <span class="badge badge-sm" style={"background-color: #{theme_color(theme)}"}></span>
              {Phoenix.Naming.humanize(theme)}
            </a>
          </li>
        <% end %>
      </ul>
    </div>

    <script>
      // Phoenix 1.8 Theme Switching Logic
      (function() {
        // Get theme from localStorage or default to system preference
        function getTheme() {
          const stored = localStorage.getItem('theme');
          if (stored) return stored;

          return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
        }

        // Set theme
        function setTheme(theme) {
          document.documentElement.setAttribute('data-theme', theme);
          localStorage.setItem('theme', theme);
        }

        // Initialize theme on page load
        document.addEventListener('DOMContentLoaded', function() {
          setTheme(getTheme());
        });

        // Listen for system theme changes
        window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(e) {
          if (!localStorage.getItem('theme')) {
            setTheme(e.matches ? 'dark' : 'light');
          }
        });

        // Handle theme switcher clicks
        document.addEventListener('click', function(e) {
          if (e.target.matches('[phx-click=\"set_theme\"]')) {
            e.preventDefault();
            const theme = e.target.getAttribute('phx-value-theme');
            setTheme(theme);

            // Close dropdown
            const dropdown = e.target.closest('.dropdown');
            if (dropdown) {
              const checkbox = dropdown.querySelector('input[type=\"checkbox\"]');
              if (checkbox) checkbox.checked = false;
            }
          }
        });
      })();
    </script>
    """
  end

  defp theme_item_class(_theme) do
    "flex items-center gap-2"
  end

  defp available_themes do
    [
      "light",
      "dark",
      "cupcake",
      "bumblebee",
      "emerald",
      "corporate",
      "synthwave",
      "retro",
      "cyberpunk",
      "valentine",
      "halloween",
      "garden",
      "forest",
      "aqua",
      "lofi",
      "pastel",
      "fantasy",
      "wireframe",
      "black",
      "luxury",
      "dracula",
      "cmyk",
      "autumn",
      "business",
      "acid",
      "lemonade",
      "night",
      "coffee",
      "winter",
      "dim",
      "nord",
      "sunset"
    ]
  end

  defp theme_color(theme) do
    case theme do
      "light" -> "#ffffff"
      "dark" -> "#1f2937"
      "cupcake" -> "#fbbf24"
      "bumblebee" -> "#f59e0b"
      "emerald" -> "#10b981"
      "corporate" -> "#3b82f6"
      "synthwave" -> "#ec4899"
      "retro" -> "#f97316"
      "cyberpunk" -> "#06b6d4"
      "valentine" -> "#f43f5e"
      "halloween" -> "#f97316"
      "garden" -> "#22c55e"
      "forest" -> "#166534"
      "aqua" -> "#06b6d4"
      "lofi" -> "#6b7280"
      "pastel" -> "#f9a8d4"
      "fantasy" -> "#c084fc"
      "wireframe" -> "#6b7280"
      "black" -> "#000000"
      "luxury" -> "#ca8a04"
      "dracula" -> "#a855f7"
      "cmyk" -> "#eab308"
      "autumn" -> "#dc2626"
      "business" -> "#3b82f6"
      "acid" -> "#84cc16"
      "lemonade" -> "#f59e0b"
      "night" -> "#0f172a"
      "coffee" -> "#92400e"
      "winter" -> "#0ea5e9"
      "dim" -> "#374151"
      "nord" -> "#5e81ac"
      "sunset" -> "#f97316"
      _ -> "#6b7280"
    end
  end
end
