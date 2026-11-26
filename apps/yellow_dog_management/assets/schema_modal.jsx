import React, { useId, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Form } from "@duskmoon-dev/components/form";
import { Input } from "@duskmoon-dev/components/input";
import { JsonSchemaForm } from "@duskmoon-dev/components/json-schema-form";
import { Modal } from "@duskmoon-dev/components/modal";
import { Validator } from "jsonschema";

const validator = new Validator();

function formDefinition(schema, initial, textFields, textValues) {
  const properties = Object.fromEntries(
    Object.entries(schema.properties).filter(([key]) => !textFields.includes(key))
  );

  return {
    schema: {
      ...schema,
      properties,
      required: schema.required.filter((key) => Object.hasOwn(properties, key)),
    },
    initialValue: () => structuredClone(Object.fromEntries(
      Object.entries(initial).filter(([key]) => Object.hasOwn(properties, key))
    )),
    validate(values) {
      const result = validator.validate({ ...values, ...textValues }, schema);
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

const emptyFields = [];

function SchemaModal({ title, schema, initial, textFields = emptyFields, submit, cancel }) {
  function initialTextValues() {
    return Object.fromEntries(textFields
      .filter((key) => !schema.properties[key].writeOnly && Object.hasOwn(initial, key))
      .map((key) => [key, initial[key]]));
  }

  const [error, setError] = useState(null);
  const [pending, setPending] = useState(false);
  const [fieldErrors, setFieldErrors] = useState({});
  const [textValues, setTextValues] = useState(initialTextValues);
  const sending = useRef(false);
  const fieldPrefix = useId();
  // The component's compiled input supports validators that run under CSP.
  const compiled = useMemo(
    () => formDefinition(schema, initial, textFields, textValues),
    [schema, initial, textFields, textValues],
  );

  function changeTextValues(values) {
    setTextValues(values);
    setFieldErrors({});
  }

  return (
    <Modal open title={title} footer={null} maskClosable={false} onCancel={cancel}>
      {error && <p role="alert" className="alert alert-error">{error}</p>}
      {pending && <p role="status">Saving…</p>}
      {textFields.map((key) => {
        const field = schema.properties[key];
        const path = "/" + key;
        const id = fieldPrefix + "-" + key;
        const fieldError = fieldErrors[path];

        return (
          <Form.Item
            key={key}
            label={field.title}
            htmlFor={id}
            required={schema.required.includes(key)}
            extra={field.description}
            help={fieldError && <span id={id + "-error"} role="alert">{fieldError}</span>}
          >
            <Input
              id={id}
              type={field.writeOnly ? "password" : "text"}
              autoComplete={field.writeOnly ? "new-password" : undefined}
              data-field-path={path}
              aria-invalid={Boolean(fieldError)}
              aria-describedby={fieldError ? id + "-error" : undefined}
              status={fieldError ? "error" : undefined}
              value={textValues[key] ?? ""}
              onChange={(event) => {
                const values = { ...textValues };
                const value = event.currentTarget.value;
                if (value.trim() === "") delete values[key];
                else values[key] = value;
                changeTextValues(values);
              }}
              onKeyDown={(event) => {
                if (event.key !== "Enter" || event.nativeEvent.isComposing) return;
                event.preventDefault();
                event.currentTarget.closest("dialog")?.querySelector("form")?.requestSubmit();
              }}
            />
          </Form.Item>
        );
      })}
      <JsonSchemaForm
        compiled={compiled}
        onErrorsChange={setFieldErrors}
        onReset={() => changeTextValues(initialTextValues())}
        onSubmit={(values) => {
          if (sending.current) return;
          sending.current = true;
          setError(null);
          setPending(true);
          submit({ ...values, ...textValues }, (reply) => {
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
