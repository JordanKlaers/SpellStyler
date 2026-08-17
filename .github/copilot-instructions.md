- DevTool:AddData is the method for which I use to debug code.
- DevTool:AddData can take either 1 or 2 arguments
- Do not ever modify the second argument when there are 2
- Do not ever remove values
- If the first argument to DevTool:AddData is a table, you can add key value pairs but do NOT ever modify or delete preexisting values
- When I want to debug, use DevTool:AddData() to display information


- Do not create md files unless I explicitly ask you to
- Do not document the code unless I explicitly ask you to

- When proposing new api methods or new solutions, determine if the methods, their arguments and their return values are secret while in combat as well as if the method can accept secret values while in combat.