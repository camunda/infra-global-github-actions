"""The YAML loader and node lookup shared by the configuration, directives, and job selection."""

from ruamel.yaml import YAML
from ruamel.yaml.nodes import MappingNode


YAML_LOADER = YAML(typ="safe", pure=True)


def child(node, key):
    """The value node under `key` in a mapping node, or None."""
    if isinstance(node, MappingNode):
        return next((value for name, value in node.value if name.value == key), None)
    return None
