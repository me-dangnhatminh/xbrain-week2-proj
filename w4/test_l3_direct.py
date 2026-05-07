#!/usr/bin/env python3
"""
Direct test of L3 tool orchestration without RAG context.
"""

import requests
import json

API_URL = "http://localhost:8001/query"

def test_l3_query(query: str, description: str):
    """Test an L3 query."""
    print(f"\n{'='*70}")
    print(f"Test: {description}")
    print(f"Query: {query}")
    print(f"{'='*70}")
    
    response = requests.post(
        API_URL,
        json={
            "query": query,
            "level": "L3"
        }
    )
    
    if response.status_code == 200:
        result = response.json()
        print(f"✅ Success!")
        print(f"Answer: {result['answer'][:200]}...")
        print(f"Tools Used: {result['tools_used']}")
        print(f"Sources: {result['sources']}")
        print(f"Processing Time: {result['processing_time']:.2f}s")
    else:
        print(f"❌ Error: {response.status_code}")
        print(response.text)
    
    return response

# Test 1: Very explicit database query
print("\n🧪 Test 1: Explicit database query")
test_l3_query(
    "Query the database to get the total cost for PaymentGW in Q1 2026 (January, February, March)",
    "Explicit database instruction"
)

# Test 2: Original query
print("\n🧪 Test 2: Original query")
test_l3_query(
    "What was PaymentGW total cost in Q1 2026?",
    "Natural language query"
)

# Test 3: Current metrics
print("\n🧪 Test 3: Current metrics")
test_l3_query(
    "What is PaymentGW's current p99 latency?",
    "Live metrics query"
)

# Test 4: Combined query
print("\n🧪 Test 4: Combined query")
test_l3_query(
    "Is NotificationSvc meeting its SLA target for p99 latency?",
    "Combined database + metrics query"
)

print("\n" + "="*70)
print("Tests completed!")
