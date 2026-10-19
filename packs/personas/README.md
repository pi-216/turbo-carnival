# Personas Pack

This pack manages personas for content creation.

## Public API

The public API for this pack is defined in the `Personas` module. To interact with personas from outside this pack, you should use the methods provided by this module.

### `Personas.create(name:)`

Creates a new persona. This is the preferred way to create persona records.

**Parameters:**

*   `name` (`String`): The name for the new persona. Must be unique.

**Returns:**

A `GLCommand::Context` object.

*   On success, the context will be successful (`context.success?` is `true`), and `context.persona` will contain the newly created `Persona` record.
*   On failure (e.g., validation error), the context will be a failure (`context.success?` is `false`), and `context.full_error_message` will contain a description of the error.

**Example:**

```ruby
result = Personas.create(name: 'Sarah')
if result.success?
  puts "Successfully created persona: #{result.persona.name}"
else
  puts "Failed to create persona: #{result.full_error_message}"
end
```

### `Personas.find(id)`

Finds a single persona by its ID.

**Parameters:**

*   `id` (`Integer`): The unique ID of the persona.

**Returns:**

*   The `Persona` object if found.
*   `nil` if no persona with the given ID exists.

**Example:**

```ruby
persona = Personas.find(1)
if persona
  puts "Found: #{persona.name}"
else
  puts 'Persona not found.'
end
```

### `Personas.find_by_name(name:)`

Finds a persona by name.

**Parameters:**

*   `name` (`String`): The name of the persona to find.

**Returns:**

*   The `Persona` object if found.
*   `nil` if no persona with the given name exists.

### `Personas.list`

Returns all personas.

**Returns:**

*   Array of `Persona` objects.
