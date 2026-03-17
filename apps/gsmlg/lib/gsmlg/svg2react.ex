defmodule GSMLG.SVG2React do
  @moduledoc """
  Convert SVG to React components using @svgr/core via Bun.

  Runs `bun --eval` with the full transformation inlined — no separate script
  file. Requires `@svgr/core` and `@svgr/babel-preset` in the workspace
  node_modules (run `bun install` from project root).
  """

  # Hyphenated SVG attribute → camelCase JSX attribute map (JSON, embedded in script).
  @attr_map ~s({"class":"className","for":"htmlFor","clip-path":"clipPath","clip-rule":"clipRule","color-interpolation":"colorInterpolation","dominant-baseline":"dominantBaseline","fill-opacity":"fillOpacity","fill-rule":"fillRule","flood-color":"floodColor","flood-opacity":"floodOpacity","font-family":"fontFamily","font-size":"fontSize","font-size-adjust":"fontSizeAdjust","font-stretch":"fontStretch","font-style":"fontStyle","font-variant":"fontVariant","font-weight":"fontWeight","image-rendering":"imageRendering","letter-spacing":"letterSpacing","lighting-color":"lightingColor","marker-end":"markerEnd","marker-mid":"markerMid","marker-start":"markerStart","paint-order":"paintOrder","pointer-events":"pointerEvents","shape-rendering":"shapeRendering","stop-color":"stopColor","stop-opacity":"stopOpacity","stroke-dasharray":"strokeDasharray","stroke-dashoffset":"strokeDashoffset","stroke-linecap":"strokeLinecap","stroke-linejoin":"strokeLinejoin","stroke-miterlimit":"strokeMiterlimit","stroke-opacity":"strokeOpacity","stroke-width":"strokeWidth","text-anchor":"textAnchor","text-decoration":"textDecoration","text-rendering":"textRendering","unicode-bidi":"unicodeBidi","vector-effect":"vectorEffect","word-spacing":"wordSpacing","writing-mode":"writingMode","xlink:href":"href","xml:space":"xmlSpace","xml:lang":"xmlLang","xmlns:xlink":null})

  @doc """
  Convert SVG code to a React component string.

  Accepts a map with a `"code"` key (the SVG) and an optional `"options"` key
  (forwarded directly to `@svgr/babel-preset`).

  Returns `{:ok, component_code}` or `{:error, reason}`.
  """
  @spec convert(map()) :: {:ok, String.t()} | {:error, term()}
  def convert(%{"code" => _} = data) do
    json = JSON.encode!(data)
    # Build a single-file Bun script with:
    #   1. Inline SVG→JSX attribute conversion (no extra deps)
    #   2. @babel/core + @svgr/babel-preset for component wrapping
    # JSON is a valid JS literal so embedding it directly is safe.
    script = """
    const i=#{json};
    const ATTR=#{@attr_map};
    const jsx=i.code
      .replace(/<!--[\\s\\S]*?-->/g,"").replace(/<\\?xml[^>]*>/g,"").replace(/<!DOCTYPE[^>]*>/gi,"")
      .replace(/\\s+xmlns:xlink="[^"]*"/g,"").trim()
      .replace(/\\s+([\\w:+-]+)="([^"]*)"/g,(_,a,v)=>{
        if(ATTR[a]===null)return "";
        const m=ATTR[a]||(a.includes("-")?a.replace(/-([a-z])/g,(_,c)=>c.toUpperCase()):null);
        return m?` ${m}="${v}"`:` ${a}="${v}"`;
      });
    const babel=require("@babel/core"),preset=require("@svgr/babel-preset"),opts=i.options||{};
    const res=babel.transformSync(jsx,{
      filename:"icon.jsx",babelrc:false,configFile:false,
      parserOpts:{plugins:["jsx"]},
      presets:[[preset,{
        dimensions:!opts.icon,expandProps:opts.expandProps||"end",
        ref:!!opts.ref,memo:!!opts.memo,icon:!!opts.icon,native:!!opts.native,
        typescript:false,titleProp:!!opts.titleProp,descProp:!!opts.descProp,
        replaceAttrValues:opts.replaceAttrValues||{},svgProps:opts.svgProps||{},
        runtimeConfig:false,state:{componentName:"SvgIcon"}
      }]]
    });
    process.stdout.write(JSON.stringify(res&&res.code));
    """

    bun = System.find_executable("bun") || raise "bun not found in PATH"
    project_root = Path.expand(Path.join([:code.priv_dir(:gsmlg), "..", "..", ".."]))

    case System.cmd(bun, ["--eval", script], cd: project_root, stderr_to_stdout: false) do
      {output, 0} -> JSON.decode(output)
      {error, _} -> {:error, String.trim(error)}
    end
  end
end
