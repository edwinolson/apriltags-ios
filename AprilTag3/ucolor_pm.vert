attribute vec4 position;

uniform mat4 PM;

void main()
{
	gl_Position = PM*position;
}
