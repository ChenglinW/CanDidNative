"""Compatibility entrypoint; implementation lives in agent_runtime."""
from agent_runtime.providers import Gateway
from agent_runtime.rules import SYSTEM
from agent_runtime.runtime import TextAgent
from tools.memory_tools import DEFINITIONS


def function(name, description, properties, required):
    return {'type': 'function', 'function': {
        'name': name, 'description': description,
        'parameters': {'type': 'object', 'properties': properties,
                       'required': required, 'additionalProperties': False}}}


TOOLS = [{'type': 'function', 'function': {
    'name': name, 'description': description, 'parameters': input_model.model_json_schema()}}
    for name, _, description, input_model in DEFINITIONS]

__all__ = ['TextAgent', 'Gateway', 'SYSTEM', 'TOOLS', 'function']
