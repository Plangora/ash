defmodule Ash.Actions.ChangesetHelpers do
  alias Ash.Actions.Filter

  def before_change(changeset, func) do
    Map.update(changeset, :__before_ash_changes__, [func], fn funcs ->
      [func | funcs]
    end)
  end

  def after_change(changeset, func) do
    Map.update(changeset, :__after_ash_changes__, [func], fn funcs ->
      [func | funcs]
    end)
  end

  def run_before_changes(%{__before_ash_changes__: hooks} = changeset) do
    Enum.reduce(hooks, changeset, fn
      hook, %Ecto.Changeset{valid?: true} = changeset ->
        case hook.(changeset) do
          :ok -> changeset
          {:ok, changeset} -> changeset
          %Ecto.Changeset{} = changeset -> changeset
        end

      _, %Ecto.Changeset{} = changeset ->
        changeset

      _, {:error, error} ->
        {:error, error}
    end)
  end

  def run_before_changes(changeset), do: changeset

  def run_after_changes(%{__after_ash_changes__: hooks} = changeset, result) do
    Enum.reduce(hooks, {:ok, result}, fn
      hook, {:ok, result} ->
        case hook.(changeset, result) do
          {:ok, result} -> {:ok, result}
          :ok -> {:ok, result}
          {:error, error} -> {:error, error}
        end

      _, {:error, error} ->
        {:error, error}
    end)
  end

  def run_after_changes(_changeset, result) do
    {:ok, result}
  end

  def belongs_to_assoc_update(
        %{__ash_api__: api} = changeset,
        %{
          destination: destination,
          destination_field: destination_field,
          source_field: source_field,
          name: rel_name
        },
        identifier,
        authorize?,
        user
      ) do
    case Filter.value_to_primary_key_filter(destination, identifier) do
      {:error, _error} ->
        Ecto.Changeset.add_error(changeset, rel_name, "Invalid primary key supplied")

      {:ok, filter} ->
        before_change(changeset, fn changeset ->
          case api.get(destination, filter, %{authorize?: authorize?, user: user}) do
            {:ok, record} ->
              changeset
              |> Ecto.Changeset.put_change(source_field, Map.get(record, destination_field))
              |> after_change(fn _changeset, result ->
                {:ok, Map.put(result, rel_name, record)}
              end)

            {:error, error} ->
              {:error, error}
          end
        end)
    end
  end

  def has_one_assoc_update(
        %{__ash_api__: api} = changeset,
        %{
          destination: destination,
          destination_field: destination_field,
          source_field: source_field,
          name: rel_name
        },
        identifier,
        authorize?,
        user
      ) do
    case Filter.value_to_primary_key_filter(destination, identifier) do
      {:error, _error} ->
        Ecto.Changeset.add_error(changeset, rel_name, "Invalid primary key supplied")

      {:ok, filter} ->
        after_change(changeset, fn _changeset, result ->
          value = Map.get(result, source_field)

          with {:ok, record} <-
                 api.get(destination, filter, %{authorize?: authorize?, user: user}),
               {:ok, updated_record} <-
                 api.update(record, %{attributes: %{destination_field => value}}) do
            {:ok, Map.put(result, rel_name, updated_record)}
          end
        end)
    end
  end

  def has_many_assoc_update(changeset, %{name: rel_name}, identifier, _, _)
      when not is_list(identifier) do
    Ecto.Changeset.add_error(changeset, rel_name, "Invalid value")
  end

  def has_many_assoc_update(
        %{__ash_api__: api} = changeset,
        %{
          destination: destination,
          destination_field: destination_field,
          source_field: source_field,
          name: rel_name
        },
        identifiers,
        authorize?,
        user
      ) do
    case values_to_primary_key_filters(destination, identifiers) do
      {:error, _error} ->
        Ecto.Changeset.add_error(changeset, rel_name, "Invalid primary key supplied")

      {:ok, filters} ->
        after_change(changeset, fn _changeset, %resource{} = result ->
          value = Map.get(result, source_field)

          with {:ok, %{results: related}} <-
                 api.read(destination, %{
                   filter: %{from_related: {result, rel_name}},
                   paginate?: false,
                   authorize?: authorize?,
                   user: user
                 }),
               {:ok, to_relate} <-
                 get_to_relate(api, filters, destination, authorize?, user),
               to_clear <- get_no_longer_present(resource, related, to_relate),
               :ok <- clear_related(api, resource, to_clear, destination_field, authorize?, user),
               {:ok, now_related} <-
                 relate_items(api, to_relate, destination_field, value, authorize?, user) do
            Map.put(result, rel_name, now_related)
          end
        end)
    end
  end

  defp relate_items(api, to_relate, destination_field, destination_field_value, authorize?, user) do
    Enum.reduce(to_relate, {:ok, []}, fn
      to_be_related, {:ok, now_related} ->
        case api.update(to_be_related, %{
               attributes: %{destination_field => destination_field_value},
               authorize?: authorize?,
               user: user
             }) do
          {:ok, newly_related} -> [newly_related | now_related]
          {:error, error} -> {:error, error}
        end

      _, {:error, error} ->
        {:error, error}
    end)
  end

  defp clear_related(api, resource, to_clear, destination_key, authorize?, user) do
    Enum.reduce(to_clear, :ok, fn
      record, :ok ->
        case api.update(resource, record, %{
               attributes: %{destination_key => nil},
               authorize?: authorize?,
               user: user
             }) do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end

      _record, {:error, error} ->
        {:error, error}
    end)
  end

  defp get_no_longer_present(resource, currently_related, to_relate) do
    primary_key = Ash.primary_key(resource)

    to_relate_pkeys =
      to_relate
      |> Enum.map(&Map.take(&1, primary_key))
      |> MapSet.new()

    Enum.reject(currently_related, fn related_item ->
      MapSet.member?(to_relate_pkeys, Map.take(related_item, primary_key))
    end)
  end

  defp get_to_relate(api, filters, destination, authorize?, user) do
    Enum.reduce(filters, {:ok, nil}, fn
      filter, {:ok, _} ->
        api.get(destination, filter, %{authorize?: authorize?, user: user})

      _, {:error, error} ->
        {:error, error}
    end)
  end

  defp values_to_primary_key_filters(destination, identifiers) do
    Enum.reduce(identifiers, {:ok, []}, fn
      identifier, {:ok, filters} ->
        case Filter.value_to_primary_key_filter(destination, identifier) do
          {:ok, filter} -> [filter | filters]
          {:error, error} -> {:error, error}
        end

      _, {:error, error} ->
        {:error, error}
    end)
  end
end
