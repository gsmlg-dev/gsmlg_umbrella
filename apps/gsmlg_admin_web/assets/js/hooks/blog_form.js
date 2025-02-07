import * as React from 'react';
import { useSyncExternalStore } from 'react';
import { hydrateRoot } from 'react-dom/client';

import { Component as BlogForm } from 'gsmlg_component/assets/component/blog_form';

export const blogFormHook = {
  blogFormHook: {
    mounted() {
      const formState = new FormState();

      formState.setData = (data) => {
        // this.pushEvent("form:input", data);
        formState.assign(data);
      };

      const submit = () => {
        const data = formState.getSnapshot();
        console.log("form:submit", data);
        formState.assign({ pending: true });
        this.pushEvent("form:submit", { blog: data }, (reply, ref) => {
          formState.reset(reply);
          formState.assign({ pending: false });
        });
      };

      function LiveViewForm({ }) {

        const data = useSyncExternalStore(formState.subscribe, formState.getSnapshot, formState.getServerSnapshot);
        return (
          <BlogForm 
            blog={data} 
            update={formState.setData}
            submit={submit} 
            pending={false} 
          />
        );
      }
      const id = this.el.getAttribute("data-id");
      this.pushEvent("form:init", { id }, (reply, ref) => {
        formState.reset(reply);
        console.log("form:init", reply);
        this.reactRoot = hydrateRoot(this.el, <LiveViewForm />);
      });
      this.handleEvent("form:update", (data) => {
        console.log("form:update", data);
        formState.assign(data);
      });
    },
    destroyed() {
      this.reactRoot?.unmount();
    },
  }
}

class FormState {
  constructor() {
    this.subscribers = [];
    this.data = {};
    this.assign = this.assign.bind(this);
    this.subscribe = this.subscribe.bind(this);
    this.getSnapshot = this.getSnapshot.bind(this);
    this.getServerSnapshot = this.getServerSnapshot.bind(this);
  }

  assign(data) {
    this.data = {
      ...this.data,
      ...data,
    };
    console.log('assign', data);
    this.subscribers.forEach(cb => {
      console.log('assign cb', cb, this.data);
      cb(this.data);
    });
  }

  reset(data) {
    this.data = data;
    this.subscribers.forEach(cb => cb(data));
  }

  getSnapshot() {
    return this.data;
  }

  subscribe(callback) {
    this.subscribers.push(callback);
    return () => {
      this.subscribers = this.subscribers.filter(s => s !== callback);
    };
  }

  getServerSnapshot() {
    return this.data;
  }
}
