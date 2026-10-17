#!/usr/bin/env python3
# 用标准库校验清单是否符合 JSON Schema。只实现 cairn-manifest.schema.json 用到的关键字：
# $ref（本地）、type、required、properties、additionalProperties（false 或子模式）、items、enum、const、
# minLength、anyOf、not、if/then/else。测试容器内没有 jsonschema，故不引入第三方依赖。
#
# 用法：validate_manifest.py <schema.json> <manifest.json>
# 退出码：0 通过；1 不通过；2 用法或读取错误。
import json
import sys


def resolve(root, ref):
    if not ref.startswith("#/"):
        raise ValueError("仅支持本地引用：" + ref)
    node = root
    for part in ref[2:].split("/"):
        node = node[part]
    return node


def check(schema, value, root, path, errors):
    if "$ref" in schema:
        return check(resolve(root, schema["$ref"]), value, root, path, errors)

    expected = schema.get("type")
    types = {"object": dict, "array": list, "string": str, "boolean": bool}
    if expected is not None and not isinstance(value, types[expected]):
        errors.append("%s: 应为 %s" % (path, expected))
        return

    if "const" in schema and value != schema["const"]:
        errors.append("%s: 应为 %r" % (path, schema["const"]))
    if "enum" in schema and value not in schema["enum"]:
        errors.append("%s: 取值须为 %s 之一" % (path, "/".join(schema["enum"])))
    if isinstance(value, str) and len(value) < schema.get("minLength", 0):
        errors.append("%s: 长度不得少于 %d" % (path, schema["minLength"]))

    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append("%s: 缺少必需字段 %s" % (path, key))
        props = schema.get("properties", {})
        extra = schema.get("additionalProperties")
        for key, sub in value.items():
            if key in props:
                check(props[key], sub, root, path + "." + key, errors)
            elif extra is False:
                errors.append("%s: 不允许的字段 %s" % (path, key))
            elif isinstance(extra, dict):
                check(extra, sub, root, path + "." + key, errors)

    if isinstance(value, list):
        if "items" in schema:
            for i, sub in enumerate(value):
                check(schema["items"], sub, root, "%s[%d]" % (path, i), errors)

    if "anyOf" in schema:
        probes = []
        for sub in schema["anyOf"]:
            probe = []
            check(sub, value, root, path, probe)
            probes.append(probe)
        if all(probes):
            errors.append("%s: 至少需满足 anyOf 中的一项" % path)

    if "not" in schema:
        probe = []
        check(schema["not"], value, root, path, probe)
        if not probe:
            errors.append("%s: 不得满足 not 中的条件" % path)

    if "if" in schema:
        probe = []
        check(schema["if"], value, root, path, probe)
        branch = "then" if not probe else "else"
        if branch in schema:
            check(schema[branch], value, root, path, errors)


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("用法：validate_manifest.py <schema.json> <manifest.json>\n")
        return 2
    try:
        with open(argv[1], encoding="utf-8") as f:
            schema = json.load(f)
        with open(argv[2], encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        sys.stderr.write("无法读取：%s\n" % e)
        return 2

    errors = []
    check(schema, doc, schema, "$", errors)
    for err in errors:
        sys.stdout.write(err + "\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
