import React, { useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { JsonSchemaForm } from "@duskmoon-dev/components/json-schema-form";
import { Modal } from "@duskmoon-dev/components/modal";
import { Validator } from "jsonschema";

const validator = new Validator();

function formDefinition(schema, initial) {
  return {
    schema,
    initialValue: () => structuredClone(initial),
    validate(values) {
      const result = validator.validate(values, schema);
      const errors = {};

      for (const error of result.errors) {
        const path = error.name === "required" ? [...error.path, error.argument] : error.path;
        const pointer = path.map((part) => "/" + String(part).replaceAll("~", "~0").replaceAll("/", "~1")).join("");
        errors[pointer] ??= error.message;
      }

      return { valid: result.valid, errors };
    },
  };
}

function SchemaModal({ title, schema, initial, submit, cancel }) {
  const [error, setError] = useState(null);
  const [pending, setPending] = useState(false);
  const sending = useRef(false);
  // The component's compiled input supports validators that run under CSP.
  const compiled = useMemo(() => formDefinition(schema, initial), [schema, initial]);

  return (
    <Modal open title={title} footer={null} maskClosable={false} onCancel={cancel}>
      {error && <p role="alert" className="alert alert-error">{error}</p>}
      {pending && <p role="status">Saving…</p>}
      <JsonSchemaForm
        compiled={compiled}
        onSubmit={(values) => {
          if (sending.current) return;
          sending.current = true;
          setError(null);
          setPending(true);
          submit(values, (reply) => {
            sending.current = false;
            setPending(false);
            setError(reply?.error ?? null);
          });
        }}
      />
    </Modal>
  );
}

export default {
  mounted() {
    this.root = createRoot(this.el);
    const payload = JSON.parse(this.el.dataset.form);
    this.root.render(
      <SchemaModal
        {...payload}
        submit={(values, reply) => this.pushEvent("submit_modal", values, reply)}
        cancel={() => this.pushEvent("close_modal", {})}
      />,
    );
  },
  destroyed() {
    this.root.unmount();
  },
};
