import * as React from 'react';
import { useState } from 'react';
import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import {Prism as SyntaxHighlighter} from 'react-syntax-highlighter';
import {dracula} from 'react-syntax-highlighter/dist/esm/styles/prism';

export function Component({ blog, update, submit }) {
  const [value, setValue] = useState(blog.content ?? '');

  return (
    <div className="container min-h-96">
      <form className="w-full max-w-6xl flex flex-col gap-6 *:w-full" action={submit}>
        <div className="input">
          <label className="label">Slug</label>
          <input type="text" defaultValue={blog.slug} onChange={(evt) => update({ slug: evt.target.value })} />
        </div>

        <div className="input">
          <label className="label">Title</label>
          <input type="text" defaultValue={blog.title} onChange={(evt) => update({ title: evt.target.value })} />
        </div>

        <div className="input">
          <label className="label">Author</label>
          <input type="text" defaultValue={blog.author} onChange={(evt) => update({ author: evt.target.value })} />
        </div>

        <div className="input">
          <label className="label">Date</label>
          <input type="date" defaultValue={blog.date} onChange={(evt) => update({ date: evt.target.value })} />
        </div>

        <div className="tabs tabs-lift">
          <input type="radio" name="content_tab" className="tab" aria-label="Content" defaultChecked />
          <div className="tab-content border-base-300 p-6 w-full">
            <textarea
              className="w-full textarea textarea-ghost"
              rows={value.split("\n").length}
              value={value}
              onChange={(evt) => {
                setValue(evt.target.value);
                update({ content: evt.target.value });
              }}
            />
          </div>

          <input type="radio" name="content_tab" className="tab" aria-label="Preview" />
          <div className="tab-content border-base-300 p-6">
            <div className="w-full max-w-6xl flex flex-col gap-6 *:w-full">
              <div className="markdown-body px-4">
                <Markdown
                  remarkPlugins={[remarkGfm]}
                  components={{
                    code(props) {
                      const {children, className, node, ...rest} = props
                      const match = /language-(\w+)/.exec(className || '')
                      return match ? (
                        <SyntaxHighlighter
                          {...rest}
                          PreTag="div"
                          children={String(children).replace(/\n$/, '')}
                          language={match[1]}
                          style={dracula}
                        />
                      ) : (
                        <code {...rest} className={className}>
                          {children}
                        </code>
                      )
                    }
                  }}
                >
                  {value}
                </Markdown>
              </div>
            </div>
          </div>
        </div>

        <div>
          <button className="btn btn-primary" type="submit" disabled={blog.pending}>Save</button>
        </div>
      </form>

    </div>
  );
}
