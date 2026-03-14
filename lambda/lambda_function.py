
import json, boto3, uuid
from boto3.dynamodb.conditions import Attr
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table("UsersTable")
def lambda_handler(event, context):
    method = event.get("httpMethod", "")
    path = event.get("path", "")
    try:
        if method == "POST" and path == "/users": return create_user(event)
        elif method == "GET" and path == "/users": return get_all_users()
        elif method == "GET" and "/users/" in path: return get_user(event)
        elif method == "PUT" and "/users/" in path: return update_user(event)
        elif method == "DELETE" and "/users/" in path: return delete_user(event)
        else: return resp(404, {"success":False,"message":"Route not found"})
    except Exception as e: return resp(500, {"success":False,"message":str(e)})
def create_user(event):
    b = json.loads(event.get("body") or "{}")
    name = b.get("name","").strip(); email = b.get("email","").strip().lower()
    if not name or not email: return resp(400,{"success":False,"message":"name and email required"})
    if table.scan(FilterExpression=Attr("email").eq(email)).get("Items"): return resp(409,{"success":False,"message":"Email already registered: " + email})
    item = {"userId":str(uuid.uuid4()),"name":name,"email":email}
    table.put_item(Item=item)
    return resp(201,{"success":True,"message":"User created","data":item})
def get_all_users():
    users = table.scan().get("Items",[])
    return resp(200,{"success":True,"message":str(len(users))+" users found","data":users})
def get_user(event):
    uid = event.get("path","").split("/")[-1]
    user = table.get_item(Key={"userId":uid}).get("Item")
    if not user: return resp(404,{"success":False,"message":"User not found"})
    return resp(200,{"success":True,"message":"User found","data":user})
def update_user(event):
    uid = event.get("path","").split("/")[-1]
    b = json.loads(event.get("body") or "{}")
    name = b.get("name","").strip(); email = b.get("email","").strip().lower()
    if not name or not email: return resp(400,{"success":False,"message":"name and email required"})
    if not table.get_item(Key={"userId":uid}).get("Item"): return resp(404,{"success":False,"message":"User not found"})
    if table.scan(FilterExpression=Attr("email").eq(email) & Attr("userId").ne(uid)).get("Items"): return resp(409,{"success":False,"message":"Email taken: " + email})
    table.update_item(Key={"userId":uid},UpdateExpression="SET #n=:n,email=:e",ExpressionAttributeNames={"#n":"name"},ExpressionAttributeValues={":n":name,":e":email})
    return resp(200,{"success":True,"message":"User updated","data":{"userId":uid,"name":name,"email":email}})
def delete_user(event):
    uid = event.get("path","").split("/")[-1]
    if not table.get_item(Key={"userId":uid}).get("Item"): return resp(404,{"success":False,"message":"User not found"})
    table.delete_item(Key={"userId":uid})
    return resp(200,{"success":True,"message":"User deleted","data":{"userId":uid}})
def resp(s,b): return {"statusCode":s,"headers":{"Content-Type":"application/json","Access-Control-Allow-Origin":"*"},"body":json.dumps(b)}
# updated
# Fri Mar 13 17:02:06 PDT 2026
