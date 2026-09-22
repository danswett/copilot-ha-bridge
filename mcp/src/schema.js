/**
 * Turns an elicitation `requestedSchema` into dashboard options.
 *
 * This is the same shape the Copilot CLI bridge already parses: MCP elicitation and
 * Copilot's ask_user both carry `message` plus a JSON-Schema `requestedSchema`, so the
 * handling is deliberately identical.
 */

const MAX_OPTION_LENGTH = 255;

function labelsFor(property) {
  if (Array.isArray(property?.enum)) {
    return property.enum.map((value, index) => ({
      value,
      title: property.enumNames?.[index] ?? String(value),
    }));
  }
  if (Array.isArray(property?.oneOf)) {
    return property.oneOf.map((option) => ({
      value: option.const,
      title: option.title ?? String(option.const),
    }));
  }
  if (Array.isArray(property?.items?.enum)) {
    return property.items.enum.map((value) => ({ value, title: String(value) }));
  }
  if (Array.isArray(property?.items?.anyOf)) {
    return property.items.anyOf.map((option) => ({
      value: option.const,
      title: option.title ?? String(option.const),
    }));
  }
  if (property?.type === 'boolean') {
    return [
      { value: true, title: 'Yes' },
      { value: false, title: 'No' },
    ];
  }
  return null;
}

/**
 * Describes how to render a schema.
 *
 * `choice` means one field with a closed option list, which becomes a dropdown.
 * Everything else falls back to the reply box, with the field list spelled out in the
 * question so nothing is hidden from the user.
 */
export function describeSchema(schema) {
  const properties = schema?.properties ?? {};
  const names = Object.keys(properties);

  if (names.length === 1) {
    const [name] = names;
    const options = labelsFor(properties[name]);
    if (options) {
      return {
        kind: 'choice',
        field: name,
        options: options.map((option) => ({
          ...option,
          title: String(option.title).slice(0, MAX_OPTION_LENGTH),
        })),
      };
    }
  }

  return {
    kind: 'freeform',
    fields: names.map((name) => ({
      name,
      title: properties[name]?.title ?? name,
      options: labelsFor(properties[name]),
    })),
  };
}

/** A numbered outline so a freeform question still shows every field and option. */
export function outlineFor(description) {
  if (description.kind !== 'freeform' || !description.fields.length) return '';
  return description.fields
    .map((field, index) => {
      const options = field.options?.map((option) => option.title).join(' | ');
      return options ? `${index + 1}. ${field.title}: ${options}` : `${index + 1}. ${field.title}`;
    })
    .join('\n');
}

/** Maps a chosen dashboard label back to the value the schema expects. */
export function valueForLabel(description, label) {
  const match = description.options?.find((option) => option.title === label);
  return match ? match.value : label;
}
