defmodule Wardwright.Runtime.Events do
  @moduledoc false

  @pubsub Wardwright.PubSub

  def topic(:models), do: "runtime:models"
  def topic(:receipts), do: "runtime:receipts"
  def topic(:policies), do: "runtime:policies"
  def topic(:simulations), do: "runtime:simulations"
  def topic(:model, model_id, version), do: "runtime:model:#{model_id}:#{version}"

  def topic(:session, model_id, version, session_id),
    do: "runtime:session:#{model_id}:#{version}:#{session_id}"

  def subscribe(topic) when is_binary(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  def publish(topic, event) when is_binary(topic) and is_map(event) do
    Phoenix.PubSub.broadcast(@pubsub, topic, {:wardwright_runtime_event, topic, event})
    event
  end

  def publish_many(topics, event) when is_list(topics) and is_map(event) do
    Enum.each(topics, &publish(&1, event))
    event
  end
end
