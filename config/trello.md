# Trello Integration

## Board
- **Board name**: Go North Website
- **Board ID**: `69db3ecc7b5bbfc29db017c1`
- **Board URL**: https://trello.com/b/YJFD3J21/go-north-website

## Lists

| List | ID | Use |
|------|----|-----|
| To Do | `69db3ee53950069f888fbcaf` | Tasks planned but not yet started |
| In Progress | `69db3ee9e3130659642e62d8` | Tasks actively being worked on |
| Done | `69db3eec55fd152dd4ff1b48` | Completed tasks |

## MCP Tools

The Trello MCP server (`trello`) provides these tools. Use them directly — no curl needed.

### Common Operations

```
# List all cards on the board
mcp__trello__get_board_lists(boardId: "69db3ecc7b5bbfc29db017c1")

# Create a new card
mcp__trello__create_card(listId: "<list_id>", name: "Card title", desc: "Description")

# Move a card to a different list
mcp__trello__update_card(cardId: "<card_id>", listId: "<target_list_id>")

# Add a comment to a card
mcp__trello__add_comment(cardId: "<card_id>", text: "Status update...")

# Get cards in a specific list
mcp__trello__get_list_cards(listId: "<list_id>")
```

## Workflow

1. **New task** → Create card in "To Do" list with title and description
2. **Work starts** → Move card to "In Progress", add comment with who's working on it
3. **Work complete** → Move card to "Done", add comment with summary of what was done
4. **Status update** → Add comment to existing card with progress notes
