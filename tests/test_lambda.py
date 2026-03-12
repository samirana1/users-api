import json, sys, os
from unittest.mock import MagicMock

mock_table = MagicMock()
mock_dynamodb_resource = MagicMock()
mock_dynamodb_resource.Table.return_value = mock_table
mock_boto3 = MagicMock()
mock_boto3.resource.return_value = mock_dynamodb_resource
mock_conditions = MagicMock()
class FakeAttr:
    def __init__(self, name): self.name = name
    def eq(self, val): return MagicMock()
    def ne(self, val): return MagicMock()
    def __and__(self, other): return MagicMock()
mock_conditions.Attr = FakeAttr
mock_boto3.dynamodb = MagicMock()
mock_boto3.dynamodb.conditions = mock_conditions
sys.modules["boto3"] = mock_boto3
sys.modules["boto3.dynamodb"] = mock_boto3.dynamodb
sys.modules["boto3.dynamodb.conditions"] = mock_conditions
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../lambda"))
import lambda_function
lambda_function.table = mock_table

def make_event(method, path, body=None):
    return {"httpMethod": method, "path": path, "body": json.dumps(body) if body else None}

def test_create_user_success():
    mock_table.scan.return_value = {"Items": []}
    mock_table.put_item.return_value = {}
    result = lambda_function.lambda_handler(make_event("POST", "/users", {"name": "Ali", "email": "ali@gmail.com"}), {})
    assert result["statusCode"] == 201

def test_create_user_missing_name():
    result = lambda_function.lambda_handler(make_event("POST", "/users", {"email": "ali@gmail.com"}), {})
    assert result["statusCode"] == 400

def test_create_user_missing_email():
    result = lambda_function.lambda_handler(make_event("POST", "/users", {"name": "Ali"}), {})
    assert result["statusCode"] == 400

def test_create_user_duplicate_email():
    mock_table.scan.return_value = {"Items": [{"userId": "existing", "email": "ali@gmail.com"}]}
    result = lambda_function.lambda_handler(make_event("POST", "/users", {"name": "Ali2", "email": "ali@gmail.com"}), {})
    assert result["statusCode"] == 409

def test_get_all_users():
    mock_table.scan.return_value = {"Items": [{"userId": "1", "name": "Ali", "email": "ali@gmail.com"}]}
    result = lambda_function.lambda_handler(make_event("GET", "/users"), {})
    assert result["statusCode"] == 200

def test_get_single_user_found():
    mock_table.get_item.return_value = {"Item": {"userId": "abc", "name": "Sara", "email": "sara@gmail.com"}}
    result = lambda_function.lambda_handler(make_event("GET", "/users/abc"), {})
    assert result["statusCode"] == 200

def test_get_single_user_not_found():
    mock_table.get_item.return_value = {"Item": None}
    result = lambda_function.lambda_handler(make_event("GET", "/users/bad-id"), {})
    assert result["statusCode"] == 404

def test_update_user_success():
    mock_table.get_item.return_value = {"Item": {"userId": "abc", "name": "Ali", "email": "ali@gmail.com"}}
    mock_table.scan.return_value = {"Items": []}
    mock_table.update_item.return_value = {}
    result = lambda_function.lambda_handler(make_event("PUT", "/users/abc", {"name": "Ali Updated", "email": "ali@gmail.com"}), {})
    assert result["statusCode"] == 200

def test_update_user_not_found():
    mock_table.get_item.return_value = {"Item": None}
    result = lambda_function.lambda_handler(make_event("PUT", "/users/bad", {"name": "Ali", "email": "ali@gmail.com"}), {})
    assert result["statusCode"] == 404

def test_delete_user_success():
    mock_table.get_item.return_value = {"Item": {"userId": "abc"}}
    mock_table.delete_item.return_value = {}
    result = lambda_function.lambda_handler(make_event("DELETE", "/users/abc"), {})
    assert result["statusCode"] == 200

def test_delete_user_not_found():
    mock_table.get_item.return_value = {"Item": None}
    result = lambda_function.lambda_handler(make_event("DELETE", "/users/bad"), {})
    assert result["statusCode"] == 404

def test_invalid_route():
    result = lambda_function.lambda_handler(make_event("PATCH", "/users"), {})
    assert result["statusCode"] == 404
